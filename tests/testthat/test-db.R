test_that("metadata round-trips per vintage", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)

  cs_meta_init(con)
  cs_meta_write(con, 1996, list(schema_version = 1L, crs = "EPSG:3347",
                                coverage = "urban"))
  cs_meta_write(con, 2021, list(schema_version = 1L, coverage = "national"))

  expect_equal(cs_meta_value(con, 1996, "coverage"), "urban")
  expect_equal(cs_meta_value(con, 2021, "coverage"), "national")
  expect_equal(cs_meta_value(con, 2021, "missing", default = "x"), "x")

  # Re-writing a key replaces it rather than appending a second row.
  cs_meta_write(con, 1996, list(coverage = "national"))
  expect_equal(cs_meta_value(con, 1996, "coverage"), "national")
  expect_equal(nrow(cs_meta_read(con, 1996)), 3L)
})

test_that("a vintage is only usable when table and schema version agree", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)
  cs_meta_init(con)

  DBI::dbExecute(con, "CREATE TABLE rnf_2011 (vintage INTEGER);")
  cs_meta_write(con, 2011, list(schema_version = cs_schema_version()))
  expect_equal(cs_db_vintages(con), 2011L)
  expect_true(cs_db_has_vintage(con, 2011))

  # A cache written by an older schema is stale, not usable.
  cs_meta_write(con, 2011, list(schema_version = 0L))
  expect_false(cs_db_has_vintage(con, 2011))

  # Metadata for a table that no longer exists is not reported either.
  cs_meta_write(con, 2016, list(schema_version = cs_schema_version()))
  expect_equal(cs_db_vintages(con), 2011L)
})

test_that("the segments view unions all three schema eras", {
  skip_if_no_duckdb_spatial()
  dir <- withr::local_tempdir()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)
  cs_meta_init(con)

  fixtures <- list(
    # SNF: lowercase, no CSD attributes at all.
    list(vintage = 1996, crs = 4267, fields = list(
      arc_id = c("S1", "S2"), name = c("Water", "Duckworth"),
      type = c("ST", "ST"), addr_fm_le = c(1L, 3L), addr_to_le = c(9L, 11L))),
    # Early RNF: RB_UID and the ADDR_* spelling.
    list(vintage = 2006, crs = 4269, fields = list(
      RB_UID = c("E1", "E2"), NAME = c("King", "Queen"),
      TYPE = c("RD", "AVE"), ADDR_FM_LE = c(2L, 4L),
      ADDR_TO_LE = c(98L, 198L))),
    # Modern RNF: NGD_UID plus the geography attributes.
    list(vintage = 2011, crs = 4269, fields = list(
      NGD_UID = c("M1", "M2"), NAME = c("Main", "Cambie"),
      TYPE = c("ST", "ST"), AFL_VAL = c(100L, 200L),
      ATL_VAL = c(198L, 298L), CSDNAME_L = c("Vancouver", "Vancouver"),
      PRUID_L = c("59", "59"))))

  for (f in fixtures) {
    path <- write_fixture_shp(dir, paste0("v", f$vintage), f$fields,
                              crs = f$crs)
    table <- cs_table_name(f$vintage)
    DBI::dbExecute(con, cs_create_table_sql(con, table))
    DBI::dbExecute(con, cs_harmonize_sql(con, path, cs_source(f$vintage),
                                         table))
    cs_meta_write(con, f$vintage, list(schema_version = cs_schema_version()))
  }
  cs_rebuild_segments_view(con)

  got <- DBI::dbGetQuery(con, paste(
    "SELECT vintage, count(*) AS n, count(source_id) AS ids,",
    "min(len_m) AS min_len, max(len_m) AS max_len,",
    "count(csdname_l) AS csd FROM segments GROUP BY vintage ORDER BY vintage;"))

  expect_equal(got$vintage, c(1996L, 2006L, 2011L))
  expect_equal(got$n, c(2L, 2L, 2L))

  # Every era resolves an identifier, under whatever name it spells it.
  expect_equal(got$ids, c(2L, 2L, 2L))

  # Only the modern era carries CSD names; the others stack as NULL.
  expect_equal(got$csd, c(0L, 0L, 2L))

  # len_m is metres in all three, which requires each era's own source CRS to
  # have been transformed to EPSG:3347 -- degrees would give ~0.001.
  expect_true(all(got$min_len > 10 & got$max_len < 1000))

  # Same column set and order across the union.
  cols <- DBI::dbGetQuery(con, "DESCRIBE segments;")
  expect_true(all(c("vintage", "source_id", "name", "af_l", "cmauid_r",
                    "len_m", "geom") %in% cols$column_name))

  # Dropping a vintage rebuilds the view over what is left.
  DBI::dbExecute(con, "DROP TABLE snf_1996;")
  cs_rebuild_segments_view(con)
  left <- DBI::dbGetQuery(con, "SELECT DISTINCT vintage FROM segments;")
  expect_equal(sort(left$vintage), c(2006L, 2011L))
})

test_that("connections are cached per cache path and swap read modes", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()

  a <- cs_connect(cache, read_only = FALSE)
  b <- cs_connect(cache, read_only = FALSE)
  expect_identical(a, b)          # reused, not reopened

  # A read-only request over a live writable handle keeps the writable one:
  # DuckDB allows only one process to hold the database open for writing.
  expect_true(DBI::dbIsValid(cs_connect(cache, read_only = TRUE)))

  canstreet_disconnect(cache)
  expect_false(DBI::dbIsValid(a))
})
