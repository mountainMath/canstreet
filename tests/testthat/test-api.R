test_that("the vintage listing covers the manifest and marks what is cached", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)

  out <- list_road_network_vintages(cache_path = cache)

  expect_equal(nrow(out), nrow(cs_sources()))
  expect_true(all(c("vintage", "product", "coverage", "source_crs",
                    "imported", "n_segments") %in% names(out)))
  expect_true(out$imported[out$vintage == 2011])
  expect_equal(out$n_segments[out$vintage == 2011], 5L)
  expect_false(any(out$imported[out$vintage != 2011]))
  expect_true(all(is.na(out$n_segments[out$vintage != 2011])))
})

test_that("the listing works with no cache at all", {
  out <- list_road_network_vintages(cache_path = withr::local_tempdir())
  expect_gt(nrow(out), 20)
  expect_false(any(out$imported))
})

test_that("get_road_network returns a lazy table that computes in the database", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)

  x <- get_road_network(2011, cache_path = cache)
  expect_s3_class(x, "tbl_lazy")

  # An aggregation is pushed down rather than pulled into R.
  agg <- dplyr::collect(dplyr::summarize(x, n = dplyr::n(),
                                         km = sum(len_m, na.rm = TRUE) / 1000))
  expect_equal(agg$n, 5)
  expect_gt(agg$km, 0)

  # A single vintage reads its own table, so its R-tree is available.
  expect_match(as.character(dbplyr::remote_query(x)), "rnf_2011")
})

test_that("an unknown vintage is rejected before anything is downloaded", {
  expect_error(get_road_network(1971, cache_path = withr::local_tempdir()),
               "No road network file")
})

test_that("spatial filters are validated and built as index-usable SQL", {
  bbox <- sf::st_bbox(c(xmin = -123.2, ymin = 49.2, xmax = -123.0,
                        ymax = 49.3), crs = 4326)
  sql <- cs_within_sql(bbox)

  # A literal, not a bound parameter: DuckDB's R-tree scan needs a constant on
  # the other side of ST_Intersects.
  expect_match(sql, "^ST_Intersects\\(geom, ST_GeomFromText\\('POLYGON")
  expect_false(grepl("?", sql, fixed = TRUE))

  # Reprojected to the storage CRS on the way in.
  coords <- as.numeric(regmatches(sql, gregexpr("[0-9]+", sql))[[1]])
  expect_true(any(coords > 1e6))

  expect_error(cs_within_sql(sf::st_bbox(c(xmin = 0, ymin = 0, xmax = 1,
                                           ymax = 1))),
               "no CRS")
  expect_error(cs_within_sql("Vancouver"), "must be an sf, sfc or bbox")
})

test_that("a filtered query collects to sf in the storage CRS", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)

  x <- get_road_network(2011, cache_path = cache)
  out <- collect_road_network(dplyr::filter(x, name == "Street2"))

  expect_s3_class(out, "sf")
  expect_equal(nrow(out), 1L)
  expect_equal(out$name, "Street2")
  expect_equal(sf::st_crs(out), sf::st_crs(3347))
  expect_equal(as.character(sf::st_geometry_type(out)), "LINESTRING")
})

test_that("collect_road_network reprojects on request and survives a dropped geometry", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 5)
  x <- get_road_network(2011, cache_path = cache)

  ll <- collect_road_network(x, crs = 4326)
  expect_equal(sf::st_crs(ll), sf::st_crs(4326))
  bb <- sf::st_bbox(ll)
  expect_gt(bb[["xmin"]], -125); expect_lt(bb[["xmax"]], -122)
  expect_gt(bb[["ymin"]], 48); expect_lt(bb[["ymax"]], 50)

  # A selection without `geom` comes back as a plain tibble, not an error.
  plain <- collect_road_network(dplyr::select(x, name, len_m))
  expect_s3_class(plain, "tbl_df")
  expect_false(inherits(plain, "sf"))
  expect_equal(names(plain), c("name", "len_m"))

  expect_error(collect_road_network(dplyr::tibble(a = 1)),
               "must be a lazy table")
})

test_that("export writes GeoParquet carrying the CRS", {
  skip_if_no_duckdb_spatial()
  skip_if_not_installed("arrow")
  cache <- local_fixture_db(2011, n = 5)
  out <- file.path(withr::local_tempdir(), "rnf.parquet")

  expect_equal(export_road_network(2011, out, cache_path = cache), out)
  expect_true(file.exists(out))

  meta <- arrow::read_parquet(out, as_data_frame = FALSE)$metadata
  expect_true("geo" %in% names(meta))
  geo <- jsonlite::fromJSON(meta$geo)
  expect_equal(geo$primary_column, "geom")
  expect_equal(geo$columns$geom$encoding, "WKB")
  expect_equal(geo$columns$geom$crs$id$code, 3347)

  expect_equal(nrow(arrow::read_parquet(out)), 5L)
})

test_that("the published schema matches the table the importer builds", {
  skip_if_no_duckdb_spatial()
  cache <- local_fixture_db(2011, n = 1)
  con <- cs_connect(cache, read_only = TRUE)

  schema <- canstreet_schema()
  cols <- DBI::dbGetQuery(con, "DESCRIBE rnf_2011;")

  expect_equal(schema$column, cols$column_name)
  expect_equal(schema$type, cols$column_type)
  expect_match(schema$source_columns[schema$column == "source_id"], "NGD_UID")
})
