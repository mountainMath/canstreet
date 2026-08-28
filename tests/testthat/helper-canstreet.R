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
