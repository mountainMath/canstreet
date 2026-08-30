# Every expectation here is a number known by construction from
# `write_fixture_pair()`, not a number read back off a previous run.

local_tnet_con <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  cs_load_spatial(con)
  cs_register_spatial(con)
  con
}

build_fixture <- function(con, ...) {
  args <- list(con = con, name = "fx", vintages = c(1996, 2021),
               tolerance = 20, min_segment_m = 5, quiet = TRUE)
  do.call(cs_build_tnet, utils::modifyList(args, list(...)))
  tibble::as_tibble(DBI::dbGetQuery(
    con, "SELECT * EXCLUDE (geom) FROM tnet_fx ORDER BY segment_id;"))
}

test_that("segments carry the years they are present in", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)
  out <- build_fixture(con)

  by_name <- function(nm) out[out$name == nm & !is.na(out$name), ]

  # Identical in both vintages, and 8 m apart in the two vintages: both are
  # one segment present in both years.
  expect_equal(by_name("ALPHA")$year_key, "1996|2021")
  expect_equal(by_name("ALPHA")$len_m, 200)
  expect_equal(by_name("BETA")$year_key, "1996|2021")
  expect_equal(by_name("BETA")$len_m, 200)

  # 60 m apart under different names is two different roads, one retired and
  # one new, not one road that moved.
  expect_equal(by_name("GAMMA")$year_key, "1996")
  expect_equal(by_name("DELTA")$year_key, "2021")
  expect_equal(by_name("GAMMA")$len_m, 200)

  # Present in only one vintage each.
  expect_equal(by_name("ETA")$year_key, "1996")
  expect_equal(by_name("ZETA")$year_key, "2021")

  # 2021 splits the 1996 arc in two; both halves are present in both years.
  eps <- by_name("EPSILON")
  expect_equal(nrow(eps), 2L)
  expect_equal(sort(eps$year_key), c("1996|2021", "1996|2021"))
  expect_equal(sum(eps$len_m), 200)

  # `years` round-trips as a list column, and the derived columns agree with it.
  expect_type(out$years, "list")
  expect_equal(out$n_years, lengths(out$years))
  expect_equal(out$first_year, vapply(out$years, min, integer(1)))
  expect_equal(out$last_year, vapply(out$years, max, integer(1)))
})

test_that("geometry comes from the newest vintage a segment exists in", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)
  out <- build_fixture(con)

  # The invariant: a segment is never cut from an older file than the newest
  # year it is present in. Nothing else in the design guarantees that "prefer
  # the newer geocoding" actually happened.
  expect_true(all(out$last_year == out$spine_vintage))

  # BETA exists in both years and its geometry is the 2021 arc, 8 m from the
  # 1996 one -- checked by identity of the source arc, not by proximity.
  beta <- out[out$name == "BETA" & !is.na(out$name), ]
  expect_equal(beta$spine_vintage, 2021L)
  expect_equal(beta$spine_id, "n2")

  # A retired road can only come from the newest vintage that still had it.
  expect_equal(unique(out$spine_vintage[out$year_key == "1996"]), 1996L)
})

test_that("the same-name rescue recovers a coarsely digitized arc", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)

  # THETA is one road: a 2-point chord in 1996, a 12-point curve bowing 90 m
  # off it in 2021. No distance tolerance can span 90 m without matching
  # unrelated streets, so only the name rescue can find it.
  with_rescue <- build_fixture(con)
  theta <- with_rescue[with_rescue$name == "THETA" &
                         !is.na(with_rescue$name), ]
  expect_equal(unique(theta$year_key), "1996|2021")
  expect_equal(unique(theta$spine_vintage), 2021L)

  # Turned off, the same road reads as one retired and one new -- which is the
  # failure mode the rescue exists to prevent, so assert it explicitly.
  strict <- build_fixture(con, name_far_m = 0)
  theta <- strict[strict$name == "THETA" & !is.na(strict$name), ]
  expect_true(any(theta$year_key == "2021"))
  expect_true(any(theta$year_key == "1996"))
  expect_true(sum(theta$len_m[theta$year_key == "1996"]) > 100)
})

test_that("non-road features of the Street Network Files are dropped", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)

  # A watercourse arc in 1996 has no counterpart in a Road Network File year,
  # so left in it would be reported as a road that has been removed.
  expect_false("SOME RIVER" %in% build_fixture(con)$name)

  kept <- build_fixture(con, roads_only = FALSE)
  expect_equal(kept$year_key[kept$name == "SOME RIVER" & !is.na(kept$name)],
               "1996")
})

test_that("the crosswalk records how each year was matched", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)
  build_fixture(con)
  xw <- tibble::as_tibble(DBI::dbGetQuery(con, "SELECT * FROM tnet_fx_src;"))
  tnet <- tibble::as_tibble(DBI::dbGetQuery(
    con, "SELECT segment_id, name, year_key FROM tnet_fx;"))
  xw <- merge(xw, tnet, by = "segment_id")

  # One crosswalk row per segment per year it is present in.
  expect_equal(nrow(xw), sum(lengths(strsplit(tnet$year_key, "|",
                                              fixed = TRUE))))
  # The year the geometry came from is matched to itself.
  expect_true(all(xw$match_kind[xw$vintage == 2021 &
                                  xw$year_key == "2021"] == "spine"))
  # BETA's 1996 arc is 8 m away and agrees on name.
  beta <- xw[xw$name == "BETA" & xw$vintage == 1996, ]
  expect_equal(beta$match_kind, "geometry+name")
  expect_equal(round(beta$dist_m), 8)
  expect_true(beta$name_match)
  # THETA's 1996 arc is found only by the rescue.
  expect_equal(unique(xw$match_kind[xw$name == "THETA" & xw$vintage == 1996]),
               "name_rescue")
})

test_that("the crosswalk carries each year's own name and source file", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_pair(con)
  build_fixture(con)
  xw <- tibble::as_tibble(DBI::dbGetQuery(con, "SELECT * FROM tnet_fx_src;"))
  tnet <- tibble::as_tibble(DBI::dbGetQuery(
    con, "SELECT segment_id, name FROM tnet_fx;"))
  xw <- merge(xw, tnet, by = "segment_id")

  # `src_name` is the arc's name in its own year, where `name` is the spine's.
  expect_equal(unique(xw$src_name[xw$name == "BETA"]), "BETA")

  # A road renamed between the two years is `match_kind = "geometry"`: the
  # positions agree and the names do not, and both names are readable from
  # the crosswalk without joining back to the vintage table.
  ren <- xw[xw$name == "NEW MAIN", ]
  expect_equal(ren$src_name[ren$vintage == 1996], "OLD MAIN")
  expect_equal(ren$match_kind[ren$vintage == 1996], "geometry")
  expect_false(ren$name_match[ren$vintage == 1996])
  expect_equal(ren$src_name[ren$vintage == 2021], "NEW MAIN")

  expect_true(all(xw$source_file == "fixture"))
})

test_that("the tolerance is calibrated from the data", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_grid(con, n = 60, offset = 8)
  cal <- cs_calibrate_tolerance(con, cs_tnet_stage(con, 1996)[["match"]],
                                cs_tnet_stage(con, 2021)[["match"]])
  expect_true(cal$calibrated)
  expect_equal(cal$n_pairs, 60L)
  # Every pair is offset by exactly 8 m, so the recall side of the tolerance is
  # 8 m and the answer is the floor of the allowed range, not the ceiling.
  expect_equal(unname(cal$recall[["90%"]]), 8)
  expect_equal(cal$tolerance_m, 10)
})

test_that("a systematic offset between vintages is reported", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  write_fixture_grid(con, n = 60, offset = 0, shift = c(0, 20))
  expect_warning(
    cs_calibrate_tolerance(con, cs_tnet_stage(con, 1996)[["match"]],
                           cs_tnet_stage(con, 2021)[["match"]]),
    "systematically displaced")
})

test_that("a build is described and can be removed", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)
  write_fixture_pair(con)
  cs_build_tnet(con, "fx", c(1996, 2021), tolerance = 20, min_segment_m = 5,
                region_note = "synthetic", quiet = TRUE)

  builds <- list_temporal_networks(cache_path = cache)
  expect_equal(builds$name, "fx")
  expect_equal(builds$vintages, "1996,2021")
  expect_false(builds$regional)
  expect_equal(builds$region_note, "synthetic")
  expect_gt(builds$total_km, 0)

  expect_s3_class(get_temporal_network("fx", cache_path = cache), "tbl_sql")
  expect_error(get_temporal_network("nope", cache_path = cache),
               "No temporal network build")

  remove_temporal_network("fx", cache_path = cache)
  expect_equal(nrow(list_temporal_networks(cache_path = cache)), 0L)
})

test_that("a build over any subset of vintages, and removing its source", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)
  write_fixture_pair(con)

  # The years are the caller's choice, not a fixed census series: with no
  # `vintages` the build takes everything the cache holds.
  cs_build_tnet(con, "all", NULL, tolerance = 20, min_segment_m = 5,
                quiet = TRUE)
  expect_equal(list_temporal_networks(cache_path = cache)$vintages,
               "1996,2021")

  # Removing a vintage takes the builds that were made from it, which can no
  # longer be rebuilt or checked.
  removed <- remove_canstreet_cache(1996, cache_path = cache)
  expect_equal(attr(removed, "builds_removed"), "all")
  expect_equal(nrow(list_temporal_networks(cache_path = cache)), 0L)
})

test_that("a build needs at least two vintages", {
  skip_if_no_duckdb_spatial()
  con <- local_tnet_con()
  expect_error(cs_build_tnet(con, "fx", 2021, quiet = TRUE),
               "at least two years")
  expect_error(cs_build_tnet(con, "fx", NULL, quiet = TRUE),
               "at least two years")
})

test_that("an sf polygon clips the build to a region", {
  skip_if_no_duckdb_spatial()
  cache <- local_cache()
  con <- cs_connect(cache, read_only = FALSE)
  write_fixture_pair(con)

  # The fixture's arcs run east from x = 0 at increasing y values, so a box
  # over the south-west quadrant has a known answer: it halves every 200 m arc
  # and excludes outright everything north of y = 350.
  region <- sf::st_sfc(sf::st_polygon(list(rbind(
    c(-50, -50), c(100, -50), c(100, 350), c(-50, 350), c(-50, -50)))),
    crs = cs_storage_crs())

  cs_build_tnet(con, "fx", c(1996, 2021), tolerance = 20, min_segment_m = 5,
                within = region, region_note = "south-west box", quiet = TRUE)
  out <- tibble::as_tibble(DBI::dbGetQuery(
    con, "SELECT * EXCLUDE (geom) FROM tnet_fx ORDER BY segment_id;"))

  # Only the arcs that reach into the box, and each one only for the part that
  # does: every arc is clipped from 200 m to 100 m.
  expect_setequal(out$name, c("ALPHA", "BETA", "GAMMA", "DELTA", "EPSILON"))
  expect_equal(out$len_m, rep(100, 5))
  expect_equal(sum(out$len_m), 500)

  # Clipping does not change what matched: the same year sets as the unclipped
  # build, for the arcs that survive it.
  key <- stats::setNames(out$year_key, out$name)
  expect_equal(unname(key[c("ALPHA", "BETA", "EPSILON")]),
               rep("1996|2021", 3))
  expect_equal(unname(key["GAMMA"]), "1996")
  expect_equal(unname(key["DELTA"]), "2021")

  builds <- list_temporal_networks(cache_path = cache)
  expect_true(builds$regional)
  expect_equal(builds$region_note, "south-west box")
})

test_that("the folded name normalizes a numeric ordinal and nothing else", {
  skip_if_no_duckdb_spatial()
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  cs_load_spatial(con)

  fold <- function(x) {
    DBI::dbGetQuery(con, paste0(
      "SELECT ", cs_name_fold_sql("n"), " AS f FROM (SELECT ",
      if (is.na(x)) "NULL::VARCHAR" else DBI::dbQuoteString(con, x),
      " AS n)"))$f
  }

  # Statistics Canada respells Vancouver's grid at 2001; both must fold alike,
  # or the name rescue cannot fire across that boundary.
  expect_identical(fold("15th"), "15")
  expect_identical(fold("15"), "15")
  expect_identical(fold("21st"), "21")
  expect_identical(fold("22nd"), "22")
  expect_identical(fold("23rd"), "23")
  expect_identical(fold("20TH"), "20")

  # Narrow on purpose: digits plus a suffix and nothing else.
  expect_identical(fold("1st Avenue"), "1ST AVENUE")
  expect_identical(fold("Front"), "FRONT")
  expect_identical(fold("Main"), "MAIN")
  expect_identical(fold("15th Line"), "15TH LINE")
  expect_identical(fold("St Clair"), "ST CLAIR")

  # The two properties the rules rely on are unchanged.
  expect_identical(fold("Rue Séraphin"), "RUE SERAPHIN")
  expect_identical(fold(NA_character_), "")
})
