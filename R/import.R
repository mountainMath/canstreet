# Import and harmonization.
#
# The attribute schema of these files changes repeatedly across the series --
# the identifier column alone is `ARC_ID` in 1991, `arc_id` in 1996 and 2001,
# `NGD_ID` in 2005, `RB_UID` in 2007 and `NGD_UID` from 2011 -- and the case of
# every column name changes with it. Rather than branch on vintage, the import
# matches the columns that are actually present against an alias table. A
# vintage that arrives with a column this package has never seen imports with
# that field NULL rather than failing, and adding it later is one line here.

#' Target column layout of a harmonized vintage table
#'
#' `NULL` type means the column is only ever derived, never mapped.
#' @keywords internal
#' @noRd
cs_target_schema <- function() {
  tibble::tribble(
    ~column,      ~type,      ~aliases,
    "source_id",  "VARCHAR",  c("NGD_UID", "NGDUID", "NGD_ID", "RB_UID", "ARC_ID"),
    "name",       "VARCHAR",  "NAME",
    "type",       "VARCHAR",  "TYPE",
    "dir",        "VARCHAR",  c("DIR", "DIRECTION"),
    "af_l",       "INTEGER",  c("AFL_VAL", "ADDR_FM_LE"),
    "at_l",       "INTEGER",  c("ATL_VAL", "ADDR_TO_LE"),
    "af_r",       "INTEGER",  c("AFR_VAL", "ADDR_FM_RG"),
    "at_r",       "INTEGER",  c("ATR_VAL", "ADDR_TO_RG"),
    "class",      "VARCHAR",  "CLASS",
    "rank",       "VARCHAR",  "RANK",
    "csduid_l",   "VARCHAR",  "CSDUID_L",
    "csduid_r",   "VARCHAR",  "CSDUID_R",
    "csdname_l",  "VARCHAR",  "CSDNAME_L",
    "csdname_r",  "VARCHAR",  "CSDNAME_R",
    "csdtype_l",  "VARCHAR",  "CSDTYPE_L",
    "csdtype_r",  "VARCHAR",  "CSDTYPE_R",
    "cmauid_l",   "VARCHAR",  "CMAUID_L",
    "cmauid_r",   "VARCHAR",  "CMAUID_R",
    "pruid_l",    "VARCHAR",  "PRUID_L",
    "pruid_r",    "VARCHAR",  "PRUID_R"
  )
}

#' Full DDL for a vintage table
#' @keywords internal
#' @noRd
cs_create_table_sql <- function(con, table) {
  schema <- cs_target_schema()
  cols <- paste0("  ", DBI::dbQuoteIdentifier(con, schema$column), " ",
                 schema$type, collapse = ",\n")
  paste0(
    "CREATE OR REPLACE TABLE ", DBI::dbQuoteIdentifier(con, table), " (\n",
    "  vintage INTEGER,\n",
    "  source_file VARCHAR,\n",
    cols, ",\n",
    "  len_m DOUBLE,\n",
    "  geom GEOMETRY\n);")
}

# `ST_Read` on the RNF shapefile needs ENCODING=ISO-8859-1. The .dbf is Latin-1
# with no .cpg, and without the option the first accented street name aborts
# the scan with `invalid code point detected in Utf8Proc::UTF8ToCodepoint` --
# which surfaces at the first string operation, not at read, so it looks like a
# problem with string folding rather than with the file.
cs_st_read_sql <- function(path) {
  paste0("st_read('", gsub("'", "''", path),
         "', open_options = ['ENCODING=ISO-8859-1'])")
}

#' Build the INSERT that harmonizes one shapefile into a vintage table
#'
#' @param con A DuckDB connection.
#' @param path Path to the shapefile.
#' @param src A one-row source manifest entry.
#' @param table Destination table.
#' @return A SQL string.
#' @keywords internal
#' @noRd
cs_harmonize_sql <- function(con, path, src, table) {
  reader <- cs_st_read_sql(path)
  present <- DBI::dbGetQuery(con, paste0("DESCRIBE SELECT * FROM ", reader, ";"))
  available <- present$column_name
  lookup <- stats::setNames(available, toupper(available))

  schema <- cs_target_schema()
  exprs <- vapply(seq_len(nrow(schema)), function(i) {
    hit <- lookup[intersect(schema$aliases[[i]], names(lookup))]
    if (!length(hit)) {
      return(paste0("CAST(NULL AS ", schema$type[i], ")"))
    }
    col <- DBI::dbQuoteIdentifier(con, unname(hit[1]))
    if (schema$type[i] == "VARCHAR") {
      # These files spell "no value" three ways on top of a real NULL: the
      # empty string everywhere, the literal "N/A" in the modern RNF, and a
      # bare underscore throughout 2001. Left alone, every comparison against
      # a parsed street type gains values that are neither match nor miss.
      paste0("nullif(nullif(nullif(trim(CAST(", col,
             " AS VARCHAR)), ''), 'N/A'), '_')")
    } else {
      paste0("TRY_CAST(", col, " AS ", schema$type[i], ")")
    }
  }, character(1))

  # Strip any CRS tag ST_Read attached before reprojecting: the target column
  # must be plain GEOMETRY to stay RTREE-indexable, and several vintages carry
  # a degenerate projection string that would not survive a transform anyway.
  geom <- cs_to_storage_sql("st_geomfromwkb(st_aswkb(geom))", src$crs)

  paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(con, table), " SELECT\n",
    "  ", src$vintage, " AS vintage,\n",
    "  ", DBI::dbQuoteString(con, basename(path)), " AS source_file,\n",
    paste0("  ", exprs, " AS ",
           DBI::dbQuoteIdentifier(con, schema$column), collapse = ",\n"), ",\n",
    "  st_length(", geom, ") AS len_m,\n",
    "  ", geom, " AS geom\n",
    "FROM ", reader, "\n",
    # A few archives bundle block or hydrography polygons beside the streets.
    "WHERE st_geometrytype(geom) IN ('LINESTRING', 'MULTILINESTRING');")
}

#' Build the INSERT that harmonizes one map sheet's AMF segments
#'
#' The Area Master Files never pass through `ST_Read`: they are parsed in R and
#' staged as a registered data frame carrying a WKT column, so this is the
#' alias table's counterpart for a source whose column names are fixed by
#' [cs_amf_segments()] rather than discovered. It is still generated from
#' [cs_target_schema()] so that a column added there cannot be forgotten here.
#'
#' One statement per UTM zone, because a zone is a different CRS and
#' `ST_SetCRS` needs a constant -- the same reason [cs_to_storage_sql()] builds
#' its SQL in R.
#'
#' @param con A DuckDB connection.
#' @param stage Name of the registered staging relation.
#' @param src A one-row source manifest entry.
#' @param table Destination table.
#' @param path Source file, recorded as `source_file`.
#' @param epsg The zone CRS this statement covers.
#' @return A SQL string.
#' @keywords internal
#' @noRd
cs_amf_harmonize_sql <- function(con, stage, src, table, path, epsg) {
  # The AMF has no segment identifier of its own, no rank, and no census
  # geography beyond the area the record sits in. Its area code is a 1976-era
  # subdivision code rather than a modern `CSDUID`, so only the name it comes
  # with is carried across; the province is the one region code that has not
  # moved, and these files are British Columbia alone.
  mapped <- c(source_id = "source_id", name = "name", type = "type",
              dir = "dir", af_l = "af_l", at_l = "at_l", af_r = "af_r",
              at_r = "at_r", class = "class",
              csdname_l = "area_name", csdname_r = "area_name",
              pruid_l = "'59'", pruid_r = "'59'")
  schema <- cs_target_schema()
  exprs <- vapply(seq_len(nrow(schema)), function(i) {
    col <- schema$column[i]
    if (col %in% names(mapped)) mapped[[col]]
    else paste0("CAST(NULL AS ", schema$type[i], ")")
  }, character(1))

  geom <- cs_to_storage_sql("st_geomfromtext(wkt)", epsg)

  paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(con, table), " SELECT\n",
    "  ", src$vintage, " AS vintage,\n",
    "  ", DBI::dbQuoteString(con, basename(path)), " AS source_file,\n",
    paste0("  ", exprs, " AS ",
           DBI::dbQuoteIdentifier(con, schema$column), collapse = ",\n"), ",\n",
    "  st_length(", geom, ") AS len_m,\n",
    "  ", geom, " AS geom\n",
    "FROM ", DBI::dbQuoteIdentifier(con, stage), "\n",
    "WHERE epsg = ", as.integer(epsg), ";")
}

#' Import one Area Master File into a vintage table
#'
#' @param con A writable DuckDB connection.
#' @param path The `.data` file.
#' @param src A one-row source manifest entry.
#' @param table Destination table.
#' @return The number of segments inserted.
#' @keywords internal
#' @noRd
cs_import_amf_file <- function(con, path, src, table) {
  segs <- cs_amf_segments(cs_amf_nodes(path))
  if (!nrow(segs)) return(0L)

  stage <- "cs_amf_stage"
  duckdb::duckdb_register(con, stage, as.data.frame(segs))
  on.exit(duckdb::duckdb_unregister(con, stage), add = TRUE)

  n <- 0L
  for (epsg in sort(unique(segs$epsg))) {
    n <- n + DBI::dbExecute(
      con, cs_amf_harmonize_sql(con, stage, src, table, path, epsg))
  }
  n
}

#' Import one vintage into the database
#'
#' @inheritParams canstreet_download
#' @param con A writable DuckDB connection.
#' @return The number of segments imported.
#' @keywords internal
#' @noRd
cs_import_vintage <- function(con, vintage, refresh = FALSE, quiet = FALSE,
                              cache_path = canstreet_cache_path()) {
  src <- cs_source(vintage)
  archives <- canstreet_download(vintage, refresh = refresh, quiet = quiet,
                                 cache_path = cache_path)
  table <- cs_table_name(vintage)

  cs_message(quiet, "Importing vintage ", src$vintage, " (", nrow(archives),
             " archive", if (nrow(archives) == 1L) "" else "s", ") ...")

  DBI::dbExecute(con, cs_create_table_sql(con, table))

  for (i in seq_len(nrow(archives))) {
    if (identical(src$archive, "none")) {
      # The Area Master Files are bare files, not archives, and no reader in
      # DuckDB or GDAL opens them; `R/amf.R` parses them into segments here.
      cs_import_amf_file(con, archives$path[i], src, table)
    } else {
      exdir <- cs_extract(archives$path[i])
      on.exit(unlink(exdir, recursive = TRUE), add = TRUE)
      shps <- cs_resolve_line_source(exdir)
      for (shp in shps) {
        DBI::dbExecute(con, cs_harmonize_sql(con, shp, src, table))
      }
      unlink(exdir, recursive = TRUE)
    }
    if (nrow(archives) > 1L && !quiet && i %% 10L == 0L) {
      message("  ", i, "/", nrow(archives), " archives")
    }
  }

  cs_normalize_address_ranges(con, table)
  # After every archive, never per archive: the ENUM is declared over the
  # values the finished table holds, and a Street Network File vintage
  # arrives as 51 shapefiles into one table.
  labelled <- cs_label_vintage(con, table, src$vintage)

  n <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n FROM ", DBI::dbQuoteIdentifier(con, table)))$n[1]
  if (n == 0L) {
    DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ",
                               DBI::dbQuoteIdentifier(con, table)))
    stop("Vintage ", src$vintage, " imported zero segments; the source files ",
         "may have changed shape. Please file an issue.", call. = FALSE)
  }

  # A vintage whose identifier column is spelled in a way the alias table does
  # not know would import silently with every source_id NULL, and only show up
  # much later as a vintage that cannot be matched to any other. Catch it here.
  n_id <- DBI::dbGetQuery(con, paste0(
    "SELECT count(source_id) AS n FROM ",
    DBI::dbQuoteIdentifier(con, table)))$n[1]
  if (n_id == 0L) {
    warning("Vintage ", src$vintage, " imported with no segment identifiers: ",
            "none of the expected identifier columns were present. Please ",
            "file an issue so the alias table can be extended.", call. = FALSE)
  }

  # The index is what makes a spatial filter ~8x faster than a full scan, and
  # DuckDB will only build it over an untagged GEOMETRY column.
  DBI::dbExecute(con, paste0(
    "CREATE INDEX ", DBI::dbQuoteIdentifier(con, paste0("idx_", table, "_geom")),
    " ON ", DBI::dbQuoteIdentifier(con, table), " USING RTREE (geom);"))

  cs_meta_write(con, src$vintage, list(
    schema_version = as.character(cs_schema_version()),
    crs = cs_storage_crs(),
    source_crs = if (identical(src$product, "AMF")) {
      # One CRS per map sheet, so the column would be a lie; the datum is what
      # is constant.
      paste0("EPSG:", src$crs, " (NAD27, projected per map sheet)")
    } else {
      paste0("EPSG:", src$crs)
    },
    product = src$product,
    catalogue = src$catalogue %||% NA_character_,
    host = src$host,
    resource = src$resource,
    coverage = src$coverage,
    n_segments = as.character(n),
    n_archives = as.character(nrow(archives)),
    package_version = as.character(utils::packageVersion("canstreet")),
    imported_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    licence = "Statistics Canada Open Licence",
    labelled_columns = if (length(labelled)) {
      paste(labelled, collapse = ", ")
    } else {
      NA_character_
    },
    notes = src$notes %||% NA_character_
  ))
  cs_rebuild_segments_view(con)

  cs_message(quiet, "Imported ", format(n, big.mark = ","), " segments for ",
             src$vintage, ".")
  n
}

#' Turn the "no address range" sentinel into a real NULL
#'
#' Every vintage marks a side of a segment that carries no civic addresses with
#' a zero range rather than with a null -- and 1991 uses `-1`. Measured on the
#' source files this is the common case, not an edge case: 2,703 of 5,192
#' segments in 1996 St. John's and 2,290 of 2,548 in the 2005 Nunavut unit.
#' Left as zeros, `is.na(af_l)` answers "never" and a minimum over the column
#' answers zero.
#'
#' Both ends of a side are cleared only when *both* are non-positive, which is
#' what the sentinel actually looks like. A side with one zero and one real
#' number does occur (135 segments in that same 1996 unit) and is a genuine
#' range that happens to start at zero, so it is left alone -- apart from a
#' negative endpoint, which is never a civic number.
#'
#' @param con A writable DuckDB connection.
#' @param table Vintage table to normalize in place.
#' @return `NULL`, invisibly.
#' @keywords internal
#' @noRd
cs_normalize_address_ranges <- function(con, table) {
  tbl <- DBI::dbQuoteIdentifier(con, table)
  for (side in c("l", "r")) {
    from <- paste0("af_", side)
    to <- paste0("at_", side)
    DBI::dbExecute(con, paste0(
      "UPDATE ", tbl, " SET ", from, " = NULL, ", to, " = NULL ",
      "WHERE coalesce(", from, ", 0) <= 0 AND coalesce(", to, ", 0) <= 0;"))
    DBI::dbExecute(con, paste0(
      "UPDATE ", tbl, " SET ", from, " = NULL WHERE ", from, " < 0;"))
    DBI::dbExecute(con, paste0(
      "UPDATE ", tbl, " SET ", to, " = NULL WHERE ", to, " < 0;"))
  }
  invisible(NULL)
}
