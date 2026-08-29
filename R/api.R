#' List the available road network vintages
#'
#' Reports every vintage this package knows how to fetch, what it covers, and
#' -- when a cache is present -- whether it has already been imported.
#'
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()],
#'   which reads the `CANSTREET_CACHE_PATH` environment variable, then the
#'   `canstreet.cache_path` option, then falls back to [tempdir()]. Set it once
#'   with [set_canstreet_cache_path()] to keep data between sessions.
#'
#' @return A [tibble::tibble()] with one row per vintage: `vintage`, `product`,
#'   `catalogue`, `host`, `coverage`, `source_crs`, `imported`, `n_segments`
#'   and `notes`.
#'
#' @examples
#' list_road_network_vintages()
#' @export
list_road_network_vintages <- function(
    cache_path = canstreet_cache_path()) {
  src <- cs_sources()
  out <- tibble::tibble(
    vintage = src$vintage,
    product = src$product,
    catalogue = src$catalogue,
    host = src$host,
    coverage = src$coverage,
    source_crs = paste0("EPSG:", src$crs),
    imported = FALSE,
    n_segments = NA_integer_,
    notes = src$notes
  )

  if (file.exists(cs_db_path(cache_path))) {
    con <- cs_connect(cache_path, read_only = TRUE)
    have <- vapply(out$vintage, function(v) cs_db_has_vintage(con, v),
                   logical(1))
    out$imported <- have
    out$n_segments <- vapply(out$vintage, function(v) {
      if (!cs_db_has_vintage(con, v)) return(NA_integer_)
      suppressWarnings(as.integer(cs_meta_value(con, v, "n_segments")))
    }, integer(1))
  }
  out
}

#' Access a road network vintage
#'
#' Downloads and imports the vintage on first use, then returns it as a lazy
#' \pkg{dbplyr} table backed by the cached 'DuckDB' store. Nothing is read into
#' memory until you call [collect_road_network()] (or [dplyr::collect()] on a
#' selection without the geometry column), so a filter or an aggregation runs
#' inside the database over all 2.2 million segments of a national vintage.
#'
#' Passing more than one vintage returns them stacked, which is the starting
#' point for comparing the network across years.
#'
#' Not everything in these files is a road. The pre-2005 releases are
#' topographic bases that carry watercourses, railways and boundaries as arcs
#' alongside the streets, and every era has a way of drawing a road that was
#' still only planned. `roads_only = TRUE` applies each vintage's own definition
#' of a road; [canstreet_road_classes()] is that definition, written out.
#'
#' Segments are harmonized into a single schema; see [canstreet_schema()]. All
#' geometry is stored in EPSG:3347 (NAD83 / Statistics Canada Lambert), so
#' `len_m` and any distance computed from `geom` are in metres regardless of
#' the vintage's own coordinate system.
#'
#' Source data are © Statistics Canada, distributed under the Statistics Canada
#' Open Licence (<https://www.statcan.gc.ca/en/reference/licence>). Cite the
#' product and reference year in anything you publish from it.
#'
#' @param vintage Reference year, or a vector of years. See
#'   [list_road_network_vintages()].
#' @param within Optional spatial filter: an \pkg{sf} or `sfc` object, or a
#'   `bbox`. Segments intersecting it are returned. Reprojected to the storage
#'   CRS for you. A filter over a single vintage uses the R-tree index.
#' @param roads_only Restrict each vintage to its road features, dropping both
#'   the non-road ones and the roads that were not yet built in its reference
#'   year. What that means is different in every vintage -- see
#'   [canstreet_road_classes()] -- and in several of them it is most of the
#'   file: a third of the 1991 and 1996 Street Network Files is watercourses,
#'   railways, hydro lines and boundaries, and 22% of 2001's length is the
#'   boundary topology of the census geography. `FALSE`, the default, returns
#'   the vintage as the source file spells it.
#'
#'   For finer control, pass the build statuses to keep instead of `TRUE`:
#'   `c("operational", "unknown")` is what `TRUE` means, and adding `"planned"`
#'   or `"under_construction"` keeps the roads a vintage drew before they were
#'   built. That matters for geocoding -- the 194 arcs 2016 classes "Planned"
#'   carry 177 addressed block faces, all of which are real streets by 2021 --
#'   and it is the wrong choice for dating a road, which is why
#'   [build_temporal_network()] keeps the default.
#' @param refresh Re-download and re-import even if the vintage is cached.
#' @param quiet Suppress progress messages.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()],
#'   which reads the `CANSTREET_CACHE_PATH` environment variable, then the
#'   `canstreet.cache_path` option, then falls back to [tempdir()]. Set it once
#'   with [set_canstreet_cache_path()] to keep data between sessions.
#'
#' @return A lazy [dplyr::tbl()] over the cached database.
#'
#' @seealso [collect_road_network()] to materialize the result as \pkg{sf},
#'   [export_road_network()] to write GeoParquet.
#'
#' @examples
#' \dontrun{
#' library(dplyr)
#'
#' # First call downloads ~310 MB and imports it; later calls are instant.
#' roads <- get_road_network(2021)
#'
#' # Aggregation runs in the database, not in R.
#' roads |>
#'   group_by(pruid_l) |>
#'   summarize(km = sum(len_m, na.rm = TRUE) / 1000) |>
#'   collect()
#'
#' # Spatial filter, materialized as sf.
#' bbox <- sf::st_bbox(c(xmin = -123.2, ymin = 49.2, xmax = -123.0,
#'                       ymax = 49.3), crs = 4326)
#' vancouver <- get_road_network(2021, within = bbox) |>
#'   collect_road_network()
#'
#' # Only the streets: 1996 carries the Fraser River and the CPR yards too.
#' get_road_network(1996, roads_only = TRUE) |>
#'   summarize(km = sum(len_m) / 1000) |>
#'   collect()
#' }
#' @export
get_road_network <- function(vintage,
                             within = NULL,
                             roads_only = FALSE,
                             refresh = FALSE,
                             quiet = FALSE,
                             cache_path = canstreet_cache_path()) {
  vintages <- vapply(vintage, cs_check_vintage, integer(1))

  # Import needs the write lock, so any cached read-only connection has to go
  # first; taking the write connection only when there is work to do keeps the
  # common case (everything already imported) lock-free.
  needed <- vintages
  if (file.exists(cs_db_path(cache_path)) && !refresh) {
    con <- cs_connect(cache_path, read_only = TRUE)
    needed <- vintages[!vapply(vintages, function(v) cs_db_has_vintage(con, v),
                               logical(1))]
  }
  if (length(needed)) {
    con <- cs_connect(cache_path, read_only = FALSE)
    for (v in needed) {
      cs_import_vintage(con, v, refresh = refresh, quiet = quiet,
                        cache_path = cache_path)
    }
  }

  con <- cs_connect(cache_path, read_only = TRUE)

  # A single vintage is read from its own table so that a spatial filter can
  # use that table's R-tree; several are read through the union view.
  if (length(vintages) == 1L) {
    from <- DBI::dbQuoteIdentifier(con, cs_table_name(vintages))
    where <- character(0)
  } else {
    from <- "segments"
    where <- paste0("vintage IN (", paste(vintages, collapse = ", "), ")")
  }

  if (!is.null(within)) {
    where <- c(where, cs_within_sql(within))
  }
  statuses <- cs_roads_only_statuses(roads_only)
  if (!is.null(statuses)) {
    # Over the union view each vintage constrains only its own rows, so a
    # vintage that needs no filter does not exclude the ones that do.
    where <- c(where, cs_roads_only_sql(vintages,
                                        qualify = length(vintages) > 1L,
                                        statuses = statuses))
  }

  sql <- paste0("SELECT * FROM ", from,
                if (length(where)) paste0(" WHERE ", paste(where,
                                                           collapse = " AND ")))
  dplyr::tbl(con, dbplyr::sql(sql))
}

#' Build the SQL for a spatial filter
#'
#' The geometry is embedded as a literal rather than bound as a parameter:
#' DuckDB's R-tree scan requires a constant on the other side of
#' `ST_Intersects`, and a bound parameter is not one.
#'
#' @param within An `sf`, `sfc` or `bbox` object.
#' @return A SQL predicate string.
#' @keywords internal
#' @noRd
cs_within_sql <- function(within) {
  geom <- if (inherits(within, "bbox")) {
    sf::st_as_sfc(within)
  } else if (inherits(within, "sf")) {
    sf::st_geometry(within)
  } else if (inherits(within, "sfc")) {
    within
  } else {
    stop("`within` must be an sf, sfc or bbox object, not a ",
         class(within)[1], ".", call. = FALSE)
  }

  if (is.na(sf::st_crs(geom))) {
    stop("`within` has no CRS; set one with sf::st_crs() so it can be ",
         "reprojected to the storage CRS.", call. = FALSE)
  }
  # Reprojecting in sf rather than in DuckDB keeps the transform under the
  # caller's own PROJ configuration.
  geom <- sf::st_transform(geom, cs_storage_crs())
  wkt <- sf::st_as_text(sf::st_union(geom))
  paste0("ST_Intersects(geom, ST_GeomFromText('", gsub("'", "''", wkt), "'))")
}

#' Materialize a road network query as an sf object
#'
#' Reads a lazy table from [get_road_network()] into memory, converting the
#' geometry column to \pkg{sf}. Geometry crosses the boundary as WKB, which is
#' both faster and lossless compared with going through text.
#'
#' @param x A lazy table from [get_road_network()].
#' @param crs Optional CRS to reproject to, as an EPSG code or authority
#'   string. Defaults to the storage CRS, EPSG:3347.
#'
#' @return An [sf::sf] object with `LINESTRING` geometry.
#'
#' @examples
#' \dontrun{
#' get_road_network(1996) |>
#'   dplyr::filter(name == "WATER") |>
#'   collect_road_network()
#' }
#' @export
collect_road_network <- function(x, crs = NULL) {
  if (!inherits(x, "tbl_sql")) {
    stop("`x` must be a lazy table from `get_road_network()`.", call. = FALSE)
  }
  con <- dbplyr::remote_con(x)
  inner <- dbplyr::sql_render(x)

  target <- if (is.null(crs)) cs_storage_crs() else cs_crs_string(crs)
  geom_sql <- if (identical(target, cs_storage_crs())) {
    "st_aswkb(geom)"
  } else {
    paste0("st_aswkb(st_transform(st_setcrs(geom, '", cs_storage_crs(),
           "'), '", target, "', TRUE))")
  }

  # SELECT * REPLACE keeps every column the caller selected, swapping only the
  # geometry for its WKB, so a query that already dropped `geom` still works.
  has_geom <- "geom" %in% dbplyr::op_vars(x)
  query <- if (has_geom) {
    paste0("SELECT * REPLACE (", geom_sql, " AS geom) FROM (", inner, ") q")
  } else {
    as.character(inner)
  }

  out <- tibble::as_tibble(DBI::dbGetQuery(con, query))
  if (!has_geom) return(out)

  out$geom <- sf::st_as_sfc(structure(out$geom, class = "WKB"), EWKB = TRUE)
  sf::st_sf(out, sf_column_name = "geom", crs = sf::st_crs(target))
}

#' Export a road network vintage to GeoParquet
#'
#' Writes a vintage -- or any query built on one -- to a GeoParquet file, for
#' use from Python, QGIS, DuckDB or anything else that reads the format. The
#' CRS travels with the file in its GeoParquet metadata.
#'
#' @param x A vintage year, or a lazy table from [get_road_network()].
#' @param path Output path, ending in `.parquet`.
#' @param crs Optional CRS to reproject to before writing.
#' @param roads_only Restrict the vintage to its road features, as
#'   [get_road_network()] does, and taking the same build-status vector. Used
#'   only when `x` is a year; a lazy table already carries whatever filter it
#'   was built with.
#' @param cache_path Cache directory, used when `x` is a year.
#'
#' @return `path`, invisibly.
#'
#' @examples
#' \dontrun{
#' export_road_network(2021, "rnf_2021.parquet")
#' }
#' @export
export_road_network <- function(x, path, crs = NULL, roads_only = FALSE,
                                cache_path = canstreet_cache_path()) {
  if (!inherits(x, "tbl_sql")) {
    x <- get_road_network(x, roads_only = roads_only, cache_path = cache_path)
  }
  con <- dbplyr::remote_con(x)
  inner <- dbplyr::sql_render(x)

  target <- if (is.null(crs)) cs_storage_crs() else cs_crs_string(crs)
  geom_sql <- if (identical(target, cs_storage_crs())) {
    paste0("st_setcrs(geom, '", cs_storage_crs(), "')")
  } else {
    paste0("st_transform(st_setcrs(geom, '", cs_storage_crs(), "'), '",
           target, "', TRUE)")
  }

  # The CRS tag is put back on only here: it is what makes DuckDB write the
  # GeoParquet `geo` metadata, and the column is on its way out of the
  # database, so it no longer has to stay R-tree-indexable.
  DBI::dbExecute(con, paste0(
    "COPY (SELECT * REPLACE (", geom_sql, " AS geom) FROM (", inner, ") q) TO ",
    DBI::dbQuoteString(con, path), " (FORMAT PARQUET);"))
  invisible(path)
}

#' The harmonized segment schema
#'
#' Describes the columns every vintage is mapped onto, and which source columns
#' feed each one. Useful when working out what a given vintage actually carries:
#' a column absent from a vintage's source files is `NA` throughout it rather
#' than missing from the table.
#'
#' The `type` given for `class` and `rank` is the type they are read from the
#' source files as. Both are stored as a labelled `ENUM` and come back as a
#' factor for the vintages whose vocabulary Statistics Canada published; see
#' [canstreet_domains()].
#'
#' @return A [tibble::tibble()] with `column`, `type` and `source_columns`.
#' @seealso [canstreet_domains()] for the `class` and `rank` vocabularies.
#'
#' @examples
#' canstreet_schema()
#' @export
canstreet_schema <- function() {
  schema <- cs_target_schema()
  tibble::tibble(
    column = c("vintage", "source_file", schema$column, "len_m", "geom"),
    type = c("INTEGER", "VARCHAR", schema$type, "DOUBLE", "GEOMETRY"),
    source_columns = c(
      "(reference year)",
      "(name of the source archive member)",
      vapply(schema$aliases, paste, character(1), collapse = ", "),
      "(computed: segment length in metres)",
      "(reprojected to EPSG:3347)"
    )
  )
}
