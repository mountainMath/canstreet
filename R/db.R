# The DuckDB store.
#
# All vintages live in a single database file. One table per vintage, plus a
# `segments` view unioning them: DuckDB's DELETE does not reclaim file space,
# so evicting a vintage from a shared table would mean rewriting the whole
# file, whereas DROP TABLE is instant and adding a vintage never rewrites what
# is already there.
#
# Geometry is stored as *untagged* DuckDB GEOMETRY in EPSG:3347 (NAD83 /
# Statistics Canada Lambert, metres). The CRS is deliberately kept out of the
# column type: RTREE indexes can only be built over a plain GEOMETRY column,
# and DuckDB refuses `CREATE INDEX ... USING RTREE` over GEOMETRY('EPSG:3347').
# The CRS is recorded in `canstreet_metadata` and re-attached at query time.

#' CRS geometry is stored in
#' @keywords internal
#' @noRd
cs_storage_crs <- function() "EPSG:3347"

#' Layout version of the canstreet database
#'
#' Bumped when the import produces a materially different database, so that a
#' cache written by an older version can be recognised and rebuilt.
#' @keywords internal
#' @noRd
cs_schema_version <- function() 2L

cs_db_path <- function(cache_path) {
  file.path(cs_cache_dir(cache_path), "canstreet.duckdb")
}

cs_table_name <- function(vintage) {
  src <- cs_source(vintage)
  paste0(tolower(src$product), "_", src$vintage)
}

# Load the spatial extension, installing it on first use. Uses DuckDB's own
# LOAD rather than a helper package's, because helpers that create *persistent*
# macros fail outright against the read-only connections queries run on.
cs_load_spatial <- function(con) {
  tryCatch(
    DBI::dbExecute(con, "LOAD spatial;"),
    error = function(e) {
      DBI::dbExecute(con, "INSTALL spatial;")
      DBI::dbExecute(con, "LOAD spatial;")
    })
  invisible(con)
}

# DuckDB refuses to open the same file twice in one process under different
# configurations, so a cached read-only connection has to be closed before the
# import can take a write lock. Connections are therefore cached per database
# path and swapped when the required mode changes.
cs_conn_cache <- new.env(parent = emptyenv())

# Key the cache on the database's *directory*, resolved. normalizePath() leaves
# a path whose leaf does not exist alone, so keying on the file itself would
# produce one key before the database is created and another (with macOS's
# /var -> /private/var resolved) afterwards -- two cache entries, two open
# handles on one database, and a disconnect that misses one of them. The
# directory is created by cs_cache_dir() before we get here, so it always
# resolves the same way.
cs_conn_key <- function(path) {
  file.path(normalizePath(dirname(path), mustWork = FALSE), basename(path))
}

cs_connect <- function(cache_path, read_only = TRUE) {
  path <- cs_db_path(cache_path)
  key <- cs_conn_key(path)

  cached <- cs_conn_cache[[key]]
  if (!is.null(cached)) {
    if (identical(cached$read_only, read_only) &&
        DBI::dbIsValid(cached$con)) {
      return(cached$con)
    }
    cs_disconnect_key(key)
  }

  if (read_only && !file.exists(path)) {
    stop("No canstreet database at '", path, "'.\n",
         "Import a vintage first, e.g. `get_road_network(2021)`.",
         call. = FALSE)
  }

  con <- DBI::dbConnect(duckdb::duckdb(dbdir = path, read_only = read_only))
  cs_load_spatial(con)
  cs_register_spatial(con)
  cs_conn_cache[[key]] <- list(con = con, read_only = read_only)
  con
}

cs_disconnect_key <- function(key) {
  cached <- cs_conn_cache[[key]]
  if (!is.null(cached)) {
    try(DBI::dbDisconnect(cached$con, shutdown = TRUE), silent = TRUE)
    rm(list = key, envir = cs_conn_cache)
  }
  invisible(NULL)
}

#' Close cached connections to the canstreet database
#'
#' The package keeps one DuckDB connection per cache open and reuses it. Call
#' this to release it -- before deleting the cache directory, or to let another
#' process take the write lock.
#'
#' @param cache_path Cache directory whose connection should be closed. Closes
#'   every cached connection when `NULL`.
#' @return `NULL`, invisibly.
#' @examples
#' canstreet_disconnect()
#' @export
canstreet_disconnect <- function(cache_path = NULL) {
  keys <- if (is.null(cache_path)) {
    ls(cs_conn_cache)
  } else {
    cs_conn_key(cs_db_path(cache_path))
  }
  for (k in keys) cs_disconnect_key(k)
  invisible(NULL)
}

#' Register the canstreet spatial macros on a connection
#'
#' Temporary macros, recreated per connection, so they work against read-only
#' databases and against databases built by an earlier package version.
#'
#' `always_xy` is passed on every transform. EPSG:4269 and EPSG:4267, like most
#' authority-defined geographic CRSs, declare their axes in latitude/longitude
#' order, while this package and \pkg{sf} always speak longitude/latitude.
#' Without the flag DuckDB reads a longitude of -123 as a latitude and quietly
#' returns an infinite coordinate rather than an error.
#'
#' @param con A DuckDB connection.
#' @param crs CRS of the stored geometry.
#' @return The connection, invisibly.
#' @keywords internal
#' @noRd
cs_register_spatial <- function(con, crs = cs_storage_crs()) {
  # Tags stored geometry with its CRS, restoring DuckDB's mismatch checking.
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP MACRO cs_geom(g) AS st_setcrs(g, '", crs, "');"))

  # The inverse: drops the tag so a value can go back into an indexable column.
  DBI::dbExecute(con,
    "CREATE OR REPLACE TEMP MACRO cs_store(g) AS g::GEOMETRY;")

  DBI::dbExecute(con,
    "CREATE OR REPLACE TEMP MACRO cs_wkb(g) AS st_aswkb(g);")

  cs_register_match_macros(con)

  invisible(con)
}

#' Register the temporal-matching macros
#'
#' `cs_local_az()` is the bearing of a line *near a point*, not end to end.
#' Measured on the source files, the arcs that matching gets wrong are the long
#' ones: a 5 km highway is a two-point chord in 2006 and a many-vertex curve in
#' 2021, and `ST_Azimuth(start, end)` over the whole arc describes a direction
#' no part of the road actually runs in. Taking the azimuth over a 25 m window
#' centred on the point under test compares like with like.
#'
#' The window is clamped so it always has positive extent -- an arc shorter
#' than 50 m collapses to its whole length rather than to a zero-length
#' segment, whose azimuth would be undefined.
#'
#' `cs_bearing_agree()` folds by 180 degrees, so an arc digitized in the
#' opposite direction counts as agreement, and treats an undefined bearing as
#' agreement rather than as a mismatch.
#'
#' @param con A DuckDB connection.
#' @param window_m Half-width of the bearing window, in metres.
#' @return The connection, invisibly.
#' @keywords internal
#' @noRd
cs_register_match_macros <- function(con, window_m = 25) {
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP MACRO cs_local_az(g, p) AS (\n",
    "  SELECT degrees(st_azimuth(\n",
    "    st_lineinterpolatepoint(g, greatest(0.0, least(t - w, 1.0 - 2 * w))),\n",
    "    st_lineinterpolatepoint(g, least(1.0, greatest(t + w, 2 * w)))))\n",
    "  FROM (SELECT st_linelocatepoint(g, p) AS t,\n",
    "               least(0.5, ", format(window_m, nsmall = 1),
    " / greatest(st_length(g), 1.0)) AS w));"))

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP MACRO cs_bearing_agree(a, b, tol) AS (\n",
    "  a IS NULL OR b IS NULL OR\n",
    "  least(abs(a - b), 360 - abs(a - b), abs(abs(a - b) - 180)) < tol);"))

  invisible(con)
}

#' SQL that reprojects an expression into the storage CRS
#'
#' Not a macro: `ST_SetCRS()` requires its CRS argument to be a constant, so a
#' macro parameter is a binder error. The source CRS is known wherever this is
#' needed -- at import, from the manifest; at query time, from the caller -- so
#' the SQL is built there instead.
#'
#' @param expr SQL expression yielding a geometry.
#' @param from_crs CRS of that expression, as an EPSG code or authority string.
#' @return A SQL string producing untagged geometry in the storage CRS.
#' @keywords internal
#' @noRd
cs_to_storage_sql <- function(expr, from_crs) {
  from <- cs_crs_string(from_crs)
  if (identical(from, cs_storage_crs())) {
    return(paste0("(", expr, ")::GEOMETRY"))
  }
  paste0("st_transform(st_setcrs(", expr, ", '", from, "'), '",
         cs_storage_crs(), "', TRUE)::GEOMETRY")
}

#' Render a CRS the way DuckDB's spatial extension wants it
#'
#' DuckDB wants an authority string such as `"EPSG:3347"`; the bare number that
#' \pkg{sf} accepts is a binder error there.
#'
#' @param crs An EPSG code, an authority string, or an `sf` crs object.
#' @return A length-one character CRS identifier.
#' @keywords internal
#' @noRd
cs_crs_string <- function(crs) {
  if (is.numeric(crs) && length(crs) == 1L && !is.na(crs)) {
    return(paste0("EPSG:", as.integer(crs)))
  }
  if (is.character(crs) && length(crs) == 1L && grepl("^[A-Za-z]+:[0-9]+$", crs)) {
    return(crs)
  }
  parsed <- sf::st_crs(crs)
  if (is.na(parsed)) {
    stop("Could not interpret `crs`; supply an EPSG code or an authority ",
         "string such as \"EPSG:3347\".", call. = FALSE)
  }
  if (!is.na(parsed$epsg)) paste0("EPSG:", parsed$epsg) else parsed$wkt
}

# ---- metadata ---------------------------------------------------------------

cs_meta_init <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS canstreet_metadata (
      vintage INTEGER, key VARCHAR, value VARCHAR
    );")
  invisible(con)
}

#' Write metadata rows for a vintage, replacing any already present
#' @keywords internal
#' @noRd
cs_meta_write <- function(con, vintage, values) {
  cs_meta_init(con)
  # Replace only the keys being written. Deleting the whole vintage would make
  # a single-key update silently drop `crs`, `coverage` and everything else
  # recorded at import.
  DBI::dbExecute(
    con,
    paste0("DELETE FROM canstreet_metadata WHERE vintage = ? AND key IN (",
           paste(rep("?", length(values)), collapse = ", "), ");"),
    params = c(list(as.integer(vintage)), as.list(names(values))))
  DBI::dbAppendTable(con, "canstreet_metadata", data.frame(
    vintage = as.integer(vintage),
    key = names(values),
    value = as.character(unlist(values)),
    stringsAsFactors = FALSE
  ))
  invisible(con)
}

#' Read the metadata table
#' @keywords internal
#' @noRd
cs_meta_read <- function(con, vintage = NULL) {
  if (!DBI::dbExistsTable(con, "canstreet_metadata")) {
    return(tibble::tibble(vintage = integer(), key = character(),
                          value = character()))
  }
  out <- tibble::as_tibble(
    DBI::dbGetQuery(con, "SELECT * FROM canstreet_metadata ORDER BY vintage, key;"))
  if (!is.null(vintage)) out <- out[out$vintage == as.integer(vintage), ]
  out
}

cs_meta_value <- function(con, vintage, key, default = NA_character_) {
  m <- cs_meta_read(con, vintage)
  v <- m$value[m$key == key]
  if (length(v) != 1L || is.na(v)) default else v
}

# ---- vintage bookkeeping ----------------------------------------------------

#' Vintages currently imported into a database
#' @keywords internal
#' @noRd
cs_db_vintages <- function(con) {
  m <- cs_meta_read(con)
  if (!nrow(m)) return(integer(0))
  v <- sort(unique(m$vintage[m$key == "schema_version"]))
  # Only report a vintage whose table actually survived.
  v[vapply(v, function(x) DBI::dbExistsTable(con, cs_table_name(x)),
           logical(1))]
}

#' A vintage is usable if it is present and was written by this schema version
#' @keywords internal
#' @noRd
cs_db_has_vintage <- function(con, vintage) {
  vintage <- as.integer(vintage)
  if (!vintage %in% cs_db_vintages(con)) return(FALSE)
  identical(cs_meta_value(con, vintage, "schema_version"),
            as.character(cs_schema_version()))
}

#' Rebuild the `segments` view over every imported vintage
#'
#' Recreated after any import or eviction. With no vintages imported the view
#' is dropped rather than left pointing at nothing.
#' @keywords internal
#' @noRd
cs_rebuild_segments_view <- function(con) {
  vintages <- cs_db_vintages(con)
  if (!length(vintages)) {
    DBI::dbExecute(con, "DROP VIEW IF EXISTS segments;")
    return(invisible(con))
  }
  parts <- vapply(vintages, function(v) {
    paste0("SELECT * FROM ", DBI::dbQuoteIdentifier(con, cs_table_name(v)))
  }, character(1))
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE VIEW segments AS\n",
    paste(parts, collapse = "\nUNION ALL BY NAME\n"), ";"))
  invisible(con)
}

# ---- temporal-network build metadata ----------------------------------------

#' Layout version of a temporal network build
#'
#' Kept separate from `cs_schema_version()`: a change to the matching algorithm
#' invalidates the derived tables but not the imported vintages, and must not
#' force a re-download of ~7 GB of source archives.
#'
#' 2: the crosswalk carries `source_file` and `src_name`, so a source arc is
#' identified by the pair the AMF and SNF vintages actually key on and its own
#' year's street name is readable without joining back to the vintage table.
#' @keywords internal
#' @noRd
cs_tnet_schema_version <- function() 2L

# A separate table rather than more rows in `canstreet_metadata`: that table
# keys on `vintage INTEGER`, and `cs_db_vintages()` scans it, so a build name
# stored there would neither fit the column type nor stay out of the vintage
# listing.
cs_builds_init <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS canstreet_builds (
      build VARCHAR, key VARCHAR, value VARCHAR
    );")
  invisible(con)
}

#' Write build metadata rows, replacing any already present
#' @keywords internal
#' @noRd
cs_builds_write <- function(con, build, values) {
  cs_builds_init(con)
  DBI::dbExecute(
    con,
    paste0("DELETE FROM canstreet_builds WHERE build = ? AND key IN (",
           paste(rep("?", length(values)), collapse = ", "), ");"),
    params = c(list(as.character(build)), as.list(names(values))))
  DBI::dbAppendTable(con, "canstreet_builds", data.frame(
    build = as.character(build),
    key = names(values),
    value = as.character(unlist(values)),
    stringsAsFactors = FALSE
  ))
  invisible(con)
}

#' Read the build metadata table
#' @keywords internal
#' @noRd
cs_builds_read <- function(con, build = NULL) {
  if (!DBI::dbExistsTable(con, "canstreet_builds")) {
    return(tibble::tibble(build = character(), key = character(),
                          value = character()))
  }
  out <- tibble::as_tibble(DBI::dbGetQuery(
    con, "SELECT * FROM canstreet_builds ORDER BY build, key;"))
  if (!is.null(build)) out <- out[out$build == as.character(build), ]
  out
}

cs_builds_value <- function(con, build, key, default = NA_character_) {
  m <- cs_builds_read(con, build)
  v <- m$value[m$key == key]
  if (length(v) != 1L || is.na(v)) default else v
}

#' Builds currently present in a database
#' @keywords internal
#' @noRd
cs_db_builds <- function(con) {
  m <- cs_builds_read(con)
  if (!nrow(m)) return(character(0))
  b <- sort(unique(m$build[m$key == "tnet_schema_version"]))
  b[vapply(b, function(x) DBI::dbExistsTable(con, cs_tnet_table_name(x)),
           logical(1))]
}

#' A build is usable if it is present and was written by this layout version
#' @keywords internal
#' @noRd
cs_db_has_build <- function(con, build) {
  if (!build %in% cs_db_builds(con)) return(FALSE)
  identical(cs_builds_value(con, build, "tnet_schema_version"),
            as.character(cs_tnet_schema_version()))
}
