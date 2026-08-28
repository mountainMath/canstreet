test_that("the cache listing reports what is imported and what is downloaded", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)
  dir.create(file.path(cache, "downloads", "2011"), recursive = TRUE)
  writeLines(strrep("x", 2e5), file.path(cache, "downloads", "2011", "a.zip"))

  out <- list_canstreet_cache(cache_path = cache)

  expect_s3_class(out, "tbl_df")
  expect_equal(out$vintage, 2011L)
  expect_equal(out$n_segments, 5L)
  expect_equal(out$n_archives, 1L)
  expect_gt(out$raw_mb, 0)
  expect_gt(attr(out, "db_mb"), 0)
})

test_that("an empty cache lists nothing rather than failing", {
  out <- list_canstreet_cache(cache_path = withr::local_tempdir())
  expect_equal(nrow(out), 0L)
})

test_that("removing a vintage drops the table but keeps the archives", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)
  dir.create(file.path(cache, "downloads", "2011"), recursive = TRUE)
  file.create(file.path(cache, "downloads", "2011", "a.zip"))

  remove_canstreet_cache(2011, cache_path = cache)

  con <- cs_connect(cache, read_only = TRUE)
  expect_false(DBI::dbExistsTable(con, "rnf_2011"))
  expect_equal(cs_db_vintages(con), integer(0))
  # The archives are the expensive part; keep_raw defaults to TRUE so a
  # re-import does not mean re-downloading hundreds of megabytes.
  expect_true(file.exists(file.path(cache, "downloads", "2011", "a.zip")))

  # The view is dropped rather than left pointing at a table that is gone.
  expect_false(DBI::dbExistsTable(con, "segments"))
})

test_that("keep_raw = FALSE also removes the downloaded archives", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)
  dir.create(file.path(cache, "downloads", "2011"), recursive = TRUE)
  file.create(file.path(cache, "downloads", "2011", "a.zip"))

  remove_canstreet_cache(2011, keep_raw = FALSE, cache_path = cache)
  expect_false(dir.exists(file.path(cache, "downloads", "2011")))
})

test_that("removing a vintage that was never imported is not an error", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 1)
  expect_equal(remove_canstreet_cache(2016, cache_path = cache), 2016L,
               ignore_attr = TRUE)

  # The vintage that is imported is untouched.
  con <- cs_connect(cache, read_only = TRUE)
  expect_equal(cs_db_vintages(con), 2011L)
})
