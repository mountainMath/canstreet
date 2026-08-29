# Each vintage era spells the same columns differently. The harmonizer resolves
# them by case-insensitive alias rather than by branching on the era, so these
# tests feed it one fixture per spelling and assert the same target schema
# comes out.

test_that("the modern RNF spelling maps onto the target schema", {
  skip_if_no_duckdb_spatial()
  dir <- withr::local_tempdir()
  con <- local_spatial_con()

  path <- write_fixture_shp(dir, "modern", list(
    NGD_UID  = c("1001", "1002"),
    NAME     = c("Main", "Cambie"),
    TYPE     = c("ST", "N/A"),
    DIR      = c("N", ""),
    AFL_VAL  = c(100L, 200L),
    ATL_VAL  = c(198L, 298L),
    AFR_VAL  = c(101L, 201L),
    ATR_VAL  = c(199L, 299L),
    CSDUID_L = c("5915022", "5915022"),
    CSDNAME_L = c("Vancouver", "Vancouver"),
    PRUID_L  = c("59", "59")))

  out <- import_fixture(con, path, 2011)

  expect_equal(nrow(out), 2)
  expect_equal(out$source_id, c("1001", "1002"))
  expect_equal(out$name, c("Main", "Cambie"))
  expect_equal(out$af_l, c(100L, 200L))
  expect_equal(out$at_r, c(199L, 299L))
  expect_equal(out$csdname_l, c("Vancouver", "Vancouver"))
  expect_equal(out$vintage, c(2011L, 2011L))

  # "N/A" and "" are sentinels, not values.
  expect_equal(out$type, c("ST", NA_character_))
  expect_equal(out$dir, c("N", NA_character_))

  # Columns this era does not carry are present but empty, so the union view
  # can stack it against eras that do.
  expect_true(all(is.na(out$cmauid_l)))
  expect_true(all(is.na(out$csdname_r)))
})

test_that("the early RNF and SNF spellings map onto the same schema", {
  skip_if_no_duckdb_spatial()
  dir <- withr::local_tempdir()
  con <- local_spatial_con()

  # 2001-2010: RB_UID, DIRECTION, ADDR_* -- and "_" as the null sentinel.
  early <- write_fixture_shp(dir, "early", list(
    RB_UID     = c("A1", "A2"),
    NAME       = c("King", "_"),
    TYPE       = c("RD", "AVE"),
    DIRECTION  = c("_", "W"),
    ADDR_FM_LE = c(2L, 4L),
    ADDR_TO_LE = c(98L, 198L),
    ADDR_FM_RG = c(1L, 3L),
    ADDR_TO_RG = c(99L, 199L)))

  # 1991/1996 SNF: same fields, lowercase, arc_id as the identifier.
  snf <- write_fixture_shp(dir, "snf", list(
    arc_id     = c("S1", "S2"),
    name       = c("Water", "Duckworth"),
    type       = c("ST", "ST"),
    direction  = c(NA_character_, NA_character_),
    addr_fm_le = c(10L, 20L),
    addr_to_le = c(50L, 60L),
    addr_fm_rg = c(11L, 21L),
    addr_to_rg = c(51L, 61L)), crs = 4267)

  early_out <- import_fixture(con, early, 2006, table = "early")
  snf_out <- import_fixture(con, snf, 1996, table = "snf")

  expect_equal(early_out$source_id, c("A1", "A2"))
  expect_equal(early_out$af_l, c(2L, 4L))
  expect_equal(early_out$name, c("King", NA))          # "_" is a null sentinel
  expect_equal(early_out$dir, c(NA, "W"))

  expect_equal(snf_out$source_id, c("S1", "S2"))
  expect_equal(snf_out$af_r, c(11L, 21L))
  expect_equal(snf_out$type, c("ST", "ST"))

  # Same column names and types out of both eras -- what makes the union view
  # legal.
  expect_identical(names(early_out), names(snf_out))
  expect_identical(vapply(early_out, function(x) class(x)[1], character(1)),
                   vapply(snf_out, function(x) class(x)[1], character(1)))
})

test_that("zero and negative address ranges are cleared", {
  skip_if_no_duckdb_spatial()
  dir <- withr::local_tempdir()
  con <- local_spatial_con()

  path <- write_fixture_shp(dir, "addr", list(
    NGD_UID = c("1", "2", "3", "4"),
    NAME    = c("a", "b", "c", "d"),
    AFL_VAL = c(  0L, 100L,  -1L,  10L),
    ATL_VAL = c(  0L,   0L,  50L,  20L),
    AFR_VAL = c(  0L,   0L,   0L,  11L),
    ATR_VAL = c(  0L,   0L,   0L,  21L)))

  out <- import_fixture(con, path, 2011)

  # Both ends unusable -> the pair goes; one usable end -> only the bad end
  # goes, because a range open at one end still locates the segment.
  expect_equal(out$af_l, c(NA, 100L, NA, 10L))
  expect_equal(out$at_l, c(NA, 0L, 50L, 20L))
  expect_true(all(is.na(out$af_r[1:3])))
  expect_equal(out$af_r[4], 11L)
})

test_that("geometry is reprojected to the storage CRS with metres for length", {
  skip_if_no_duckdb_spatial()
  dir <- withr::local_tempdir()
  con <- local_spatial_con()

  path <- write_fixture_shp(dir, "geo", list(
    NGD_UID = "1", NAME = "Main"), crs = 4269)
  DBI::dbExecute(con, cs_create_table_sql(con, "geo"))
  DBI::dbExecute(con, cs_harmonize_sql(con, path, cs_source(2011), "geo"))

  got <- DBI::dbGetQuery(con, paste(
    "SELECT len_m, st_geometrytype(geom) AS gtype,",
    "st_x(st_startpoint(geom)) AS x, st_y(st_startpoint(geom)) AS y",
    "FROM geo;"))

  expect_equal(as.character(got$gtype), "LINESTRING")

  # A ~0.001 degree segment near Vancouver is on the order of 100 m, which it
  # can only be if the transform to EPSG:3347 actually happened -- in degrees
  # the same figure would be ~0.001.
  expect_gt(got$len_m, 10)
  expect_lt(got$len_m, 1000)

  # StatCan Lambert puts southwestern BC around x 3.9M, y 2.0M.
  expect_gt(got$x, 3e6); expect_lt(got$x, 5e6)
  expect_gt(got$y, 1e6); expect_lt(got$y, 3e6)
})

test_that("2001's MapInfo spelling maps onto the same schema", {
  skip_if_no_duckdb_spatial()
  skip_if_not_installed("sf")
  dir <- withr::local_tempdir()
  con <- local_spatial_con()

  # The release spells the address columns in full -- and "RGHT", not "RIGHT".
  # Every other vintage ships their ten-character `.dbf` truncations, which is
  # why both spellings have to resolve to the same four target columns.
  path <- write_fixture_mif(dir, "grnf000r02ml_e", list(
    arc_id       = c(3257886L, 3257887L),
    class        = c("1011", "BO"),
    arc_group    = c("AD", "BO"),
    name         = c("Vérendrye", "_"),
    type         = c("BOUL", "_"),
    direction    = c("_", "_"),
    addr_fm_left = c(100, 0),
    addr_to_left = c(198, 0),
    addr_fm_rght = c(101, 0),
    addr_to_rght = c(199, 0)))
  expect_match(path, "\\.mif$", ignore.case = TRUE)

  out <- import_fixture(con, path, 2001)

  expect_equal(out$source_id, c("3257886", "3257887"))
  expect_equal(out$af_l, c(100L, NA_integer_))
  expect_equal(out$at_l, c(198L, NA_integer_))
  expect_equal(out$af_r, c(101L, NA_integer_))
  expect_equal(out$at_r, c(199L, NA_integer_))
  # The declared charset survives the read, so an accented name is not mangled.
  expect_equal(out$name, c("Vérendrye", NA_character_))
  # "_" is 2001's null sentinel, in the MapInfo spelling as in the coverage.
  expect_equal(out$dir, c(NA_character_, NA_character_))
  # The boundary arcs are carried, not dropped: the road filter is what drops
  # them, and only when the caller asks for it.
  expect_equal(out$class, c("1011", "BO"))
})

test_that("the MapInfo road layer is picked over the block polygons", {
  skip_if_not_installed("sf")
  dir <- withr::local_tempdir()

  # 2001 ships an `ml` line pair beside an `mp` polygon one. Nothing in the
  # names says which is which, so the choice is made on geometry.
  lines <- write_fixture_mif(dir, "grnf000r02ml_e",
                             list(arc_id = 1:2), geometry = "line")
  write_fixture_mif(dir, "grnf000r02mp_e",
                    list(block_id = 1:2), geometry = "polygon")

  expect_equal(cs_resolve_line_source(dir), lines)
})

test_that("an ArcInfo coverage is converted, then read as a shapefile", {
  skip_if_not_installed("sf")
  dir <- withr::local_tempdir()
  e00 <- file.path(dir, "grnf000r02a_e.e00")
  file.create(e00)

  # Conversion is where the coverage stops being special: everything after it
  # sees an ordinary shapefile, read with the encoding every vintage needs.
  called <- NULL
  local_mocked_bindings(
    cs_coverage_to_shapefile = function(path) {
      called <<- path
      sub("\\.e00$", "_arc.shp", path)
    })
  found <- cs_resolve_line_source(dir)
  expect_equal(called, e00)
  expect_match(found, "_arc\\.shp$")
  expect_match(cs_st_read_sql(found), "ENCODING=ISO-8859-1", fixed = TRUE)
})

test_that("a coverage is preferred over stray shapefiles in the same archive", {
  dir <- withr::local_tempdir()
  file.create(file.path(dir, "notes.shp"))
  expect_match(cs_resolve_line_source(dir), "\\.shp$")

  file.create(file.path(dir, "roads.e00"))
  local_mocked_bindings(
    cs_coverage_to_shapefile = function(path) sub("\\.e00$", "_arc.shp", path))
  expect_match(cs_resolve_line_source(dir), "roads_arc\\.shp$")
})

test_that("an archive with no readable line layer is an error, not a silence", {
  dir <- withr::local_tempdir()
  expect_error(cs_resolve_line_source(dir), "No shapefile, MapInfo file")
})

test_that("the converted coverage is asked for the ARC layer, unrecoded", {
  skip_if_not_installed("sf")
  opts <- NULL
  local_mocked_bindings(
    gdal_utils = function(util, source, destination, options, ...) {
      opts <<- options
      file.create(destination)
      TRUE
    }, .package = "sf")

  dir <- withr::local_tempdir()
  e00 <- file.path(dir, "cov.e00")
  file.create(e00)
  out <- cs_coverage_to_shapefile(e00)

  expect_equal(out, file.path(dir, "cov_arc.shp"))
  # Only the arc layer: a coverage also holds PAL, CNT and LAB.
  expect_true("SELECT * FROM ARC" %in% opts)
  # An empty layer encoding keeps the Latin-1 bytes and writes no .cpg, which
  # is the file shape `cs_st_read_sql()` already knows how to read.
  expect_equal(opts[which(opts == "-lco") + 1L], "ENCODING=")

  # A second call reuses the conversion rather than repeating it.
  opts <- NULL
  expect_equal(cs_coverage_to_shapefile(e00), out)
  expect_null(opts)
})

test_that("only the expected field-truncation warnings are muffled", {
  skip_if_not_installed("sf")
  local_mocked_bindings(
    gdal_utils = function(util, source, destination, options, ...) {
      # Both of the warnings a real conversion of the 2001 coverage emits.
      warning("GDAL Message 6: Normalized/laundered field name: ",
              "'ADDR_FM_LEFT' to 'ADDR_FM_LE'")
      warning("GDAL Message 1: Value 'NA    ' of field ARC.ADDR_TO_LEFT ",
              "parsed incompletely to integer 0.")
      file.create(destination)
      TRUE
    }, .package = "sf")

  dir <- withr::local_tempdir()
  e00 <- file.path(dir, "cov.e00")
  file.create(e00)

  seen <- character()
  withCallingHandlers(cs_coverage_to_shapefile(e00),
                      warning = function(w) {
                        seen <<- c(seen, conditionMessage(w))
                        invokeRestart("muffleWarning")
                      })

  # The truncation is the point -- it lands the columns on the ten-character
  # spellings the alias table carries -- so it is silenced. Anything else GDAL
  # has to say still gets through.
  expect_length(seen, 1L)
  expect_match(seen, "parsed incompletely to integer 0")
})
