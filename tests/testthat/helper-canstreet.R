# Skip when the DuckDB spatial extension cannot be installed or loaded --
# it is downloaded on first use, so a sandboxed or offline machine has none.
skip_if_no_duckdb_spatial <- function() {
  ok <- tryCatch({
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    cs_load_spatial(con)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) testthat::skip("DuckDB spatial extension unavailable")
}

# An isolated cache directory that is removed when the calling test ends.
local_cache <- function(env = parent.frame()) {
  path <- withr::local_tempdir(.local_envir = env)
  withr::defer(canstreet_disconnect(path), envir = env)
  path
}

# Write a small shapefile standing in for one vintage's source file. `fields`
# is a named list of attribute columns, so a test can spell the column names
# the way any given vintage does.
write_fixture_shp <- function(dir, layer, fields, crs = 4269, n = NULL) {
  n <- n %||% length(fields[[1]])
  geoms <- sf::st_sfc(lapply(seq_len(n), function(i) {
    x <- -123.1 + i / 1000
    sf::st_linestring(matrix(c(x, 49.2, x + 0.001, 49.201), ncol = 2,
                             byrow = TRUE))
  }), crs = crs)
  obj <- sf::st_sf(as.data.frame(fields, stringsAsFactors = FALSE),
                   geometry = geoms)
  path <- file.path(dir, paste0(layer, ".shp"))
  suppressWarnings(sf::st_write(obj, path, quiet = TRUE, delete_dsn = TRUE))
  path
}

# Import a fixture shapefile into `table` exactly as cs_import_vintage would.
import_fixture <- function(con, path, vintage, table = "fixture") {
  src <- cs_source(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  DBI::dbExecute(con, cs_harmonize_sql(con, path, src, table))
  cs_normalize_address_ranges(con, table)
  tibble::as_tibble(DBI::dbGetQuery(
    con, paste0("SELECT * EXCLUDE (geom) FROM ",
                DBI::dbQuoteIdentifier(con, table), " ORDER BY source_id")))
}

# An in-memory DuckDB with the spatial extension loaded.
local_spatial_con <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  cs_load_spatial(con)
  con
}

# A cache directory holding a database with one fixture vintage imported, so
# the api-level functions can be exercised without touching the network.
local_fixture_db <- function(vintage = 2011, n = 5, env = parent.frame()) {
  cache <- local_cache(env)
  dir <- withr::local_tempdir(.local_envir = env)
  con <- cs_connect(cache, read_only = FALSE)
  cs_meta_init(con)

  path <- write_fixture_shp(dir, "fx", list(
    NGD_UID = as.character(seq_len(n)),
    NAME = paste0("Street", seq_len(n)),
    TYPE = rep("ST", n),
    AFL_VAL = seq_len(n) * 100L,
    ATL_VAL = seq_len(n) * 100L + 98L,
    CSDNAME_L = rep("Vancouver", n)), crs = cs_source(vintage)$crs)

  table <- cs_table_name(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  DBI::dbExecute(con, cs_harmonize_sql(con, path, cs_source(vintage), table))
  cs_meta_write(con, vintage, list(schema_version = cs_schema_version(),
                                   crs = cs_storage_crs(), n_segments = n,
                                   n_archives = 1L,
                                   imported_at = format(Sys.time()),
                                   package_version = "0.0.0.9000"))
  cs_rebuild_segments_view(con)
  canstreet_disconnect(cache)
  cache
}

# Insert arcs straight into a vintage table, bypassing the shapefile import.
# The temporal network reads only the vintage tables, so a fixture written this
# way exercises everything under test while letting a test state its geometry in
# exact metres -- which is what makes an 8 m offset assertable as an 8 m offset.
# Coordinates are treated as EPSG:3347, but nothing in the matching is
# projection-aware, so any local metric frame does.
write_fixture_arcs <- function(con, vintage, arcs) {
  table <- cs_table_name(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  values <- vapply(seq_len(nrow(arcs)), function(i) {
    paste0("(", vintage, ", 'fixture', ",
           DBI::dbQuoteString(con, arcs$source_id[i]), ", ",
           DBI::dbQuoteString(con, arcs$name[i]), ", ",
           DBI::dbQuoteString(con, arcs$class[i] %||% NA_character_), ", ",
           "st_length(st_geomfromtext(",
           DBI::dbQuoteString(con, arcs$wkt[i]), ")), st_geomfromtext(",
           DBI::dbQuoteString(con, arcs$wkt[i]), "))")
  }, character(1))
  DBI::dbExecute(con, paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(con, table),
    " (vintage, source_file, source_id, name, class, len_m, geom) VALUES\n",
    paste(values, collapse = ",\n"), ";"))

  # Register the fixture the way an import would, so anything that asks the
  # database what it holds -- `cs_db_vintages()`, `list_canstreet_cache()`, a
  # build with `vintages = NULL` -- sees it.
  cs_meta_write(con, vintage, list(
    schema_version = as.character(cs_schema_version()),
    crs = cs_storage_crs(),
    source_crs = cs_storage_crs(),
    product = "fixture",
    host = "fixture",
    coverage = "fixture",
    n_segments = as.character(nrow(arcs)),
    n_archives = "0",
    package_version = as.character(utils::packageVersion("canstreet")),
    imported_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ))
  cs_rebuild_segments_view(con)
  invisible(table)
}

arc <- function(source_id, name, wkt, class = NA_character_) {
  data.frame(source_id = source_id, name = name, wkt = wkt, class = class,
             stringsAsFactors = FALSE)
}

# A horizontal segment of `len` metres at height `y`, as WKT.
fx_line <- function(y, x0 = 0, len = 200) {
  paste0("LINESTRING(", x0, " ", y, ", ", x0 + len, " ", y, ")")
}

# A 12-point arc bowing `rise` metres off the straight line from (0, y) to
# (len, y) -- the coarse-chord-versus-fine-curve case that the same-name rescue
# exists for.
fx_bow <- function(y, len = 1000, rise = 90, n = 12) {
  x <- seq(0, len, length.out = n)
  yy <- y + rise * (1 - (2 * x / len - 1)^2)
  paste0("LINESTRING(", paste0(round(x, 3), " ", round(yy, 3),
                               collapse = ", "), ")")
}

# Two vintages whose correct temporal answer is known by construction. See
# test-tnet.R for what each row is there to prove.
write_fixture_pair <- function(con) {
  old <- rbind(
    arc("o1", "ALPHA",   fx_line(0)),      # identical in both
    arc("o2", "BETA",    fx_line(100)),    # 8 m from its 2021 counterpart
    arc("o3", "GAMMA",   fx_line(200)),    # 60 m away, different name: retired
    arc("o4", "EPSILON", fx_line(300)),    # one arc that 2021 splits in two
    arc("o5", "ETA",     fx_line(500)),    # present only in 1996
    arc("o6", "THETA",   fx_line(600, len = 1000)),  # coarse chord
    arc("o7", "SOME RIVER", fx_line(800), class = "WCR"))  # not a road at all
  new <- rbind(
    arc("n1", "ALPHA",   fx_line(0)),
    arc("n2", "BETA",    fx_line(108)),
    arc("n3", "DELTA",   fx_line(260)),
    arc("n4", "EPSILON", fx_line(300, len = 100)),
    arc("n5", "EPSILON", fx_line(300, x0 = 100, len = 100)),
    arc("n6", "ZETA",    fx_line(400)),    # present only in 2021
    arc("n7", "THETA",   fx_bow(600)))     # the same road, finely digitized
  write_fixture_arcs(con, 1996, old)
  write_fixture_arcs(con, 2021, new)
  invisible(c(1996L, 2021L))
}

# A grid of `n` named streets, each offset by `offset` metres between the two
# vintages, plus an optional uniform `shift` applied to every 2021 arc. Enough
# pairs for cs_calibrate_tolerance() to have something to measure.
write_fixture_grid <- function(con, n = 60, offset = 8, shift = c(0, 0)) {
  nm <- sprintf("STREET %03d", seq_len(n))
  old <- do.call(rbind, lapply(seq_len(n), function(i)
    arc(paste0("o", i), nm[i], fx_line(i * 100))))
  new <- do.call(rbind, lapply(seq_len(n), function(i)
    arc(paste0("n", i), nm[i],
        paste0("LINESTRING(", shift[1], " ", i * 100 + offset + shift[2],
               ", ", 200 + shift[1], " ", i * 100 + offset + shift[2], ")"))))
  write_fixture_arcs(con, 1996, old)
  write_fixture_arcs(con, 2021, new)
  invisible(c(1996L, 2021L))
}
