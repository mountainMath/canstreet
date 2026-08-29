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

test_that("an ArcInfo coverage is staged, then read as itself", {
  dir <- withr::local_tempdir()
  e00 <- file.path(dir, "roads.e00")
  writeBin(charToRaw("EXP  0\nARC  2\n"), e00)

  found <- cs_resolve_line_source(dir)
  expect_equal(readBin(found, "raw", 100L), charToRaw("EXP  0\nARC  2\n"))

  # A coverage names its layers after their geometry, so the network has to be
  # asked for by name; the encoding option every other vintage needs rides
  # along harmlessly.
  expect_match(cs_st_read_sql(found), "layer = 'ARC'", fixed = TRUE)
  expect_match(cs_st_read_sql(found), "ENCODING=ISO-8859-1", fixed = TRUE)
  expect_false(grepl("layer", cs_st_read_sql("roads.shp"), fixed = TRUE))
})

test_that("the volumes of a multi-volume coverage are joined in order", {
  dir <- withr::local_tempdir()

  # 1991 ships its larger units as `NET_TORO.E00` beside `.E01` ... `.E11`,
  # split by byte count rather than by section. GDAL opens the first volume
  # alone and reports its share of the arcs as if it were the whole coverage,
  # without a warning, so the volumes have to be rejoined before the read.
  for (i in 0:11) {
    writeBin(charToRaw(paste0("volume", i, "\n")),
             file.path(dir, sprintf("NET_TORO.E%02d", i)))
  }

  staged <- cs_resolve_line_source(dir)
  expect_length(staged, 1L)
  expect_equal(basename(staged), "NET_TORO.E00")
  expect_equal(rawToChar(readBin(staged, "raw", 1e4L)),
               paste0(paste0("volume", 0:11, collapse = "\n"), "\n"))
})

test_that("a high byte in a coverage is folded, not widened", {
  dir <- withr::local_tempdir()
  # The non-breaking space that Toronto's `EA<a0>96` carries in 1996, and an
  # accented letter of the kind the format could hold.
  raw <- c(charToRaw("EA"), as.raw(0xa0),
           charToRaw("96 V"), as.raw(0xc9), charToRaw("RENDRYE"))
  writeBin(raw, file.path(dir, "cov.e00"))

  staged <- readBin(cs_resolve_line_source(dir), "raw", 100L)

  # Byte for byte: the fields of an interchange file are fixed width, so a
  # two-byte UTF-8 character would shift everything after it on the line.
  expect_length(staged, length(raw))
  expect_equal(rawToChar(staged), "EA 96 VERENDRYE")
  expect_true(validUTF8(rawToChar(staged)))
})

test_that("a coverage is preferred over stray shapefiles in the same archive", {
  dir <- withr::local_tempdir()
  file.create(file.path(dir, "notes.shp"))
  expect_match(cs_resolve_line_source(dir), "\\.shp$")

  writeBin(charToRaw("EXP  0\n"), file.path(dir, "roads.e00"))
  expect_match(cs_resolve_line_source(dir), "canstreet_staged/roads\\.e00$")
})

test_that("an archive with no readable line layer is an error, not a silence", {
  dir <- withr::local_tempdir()
  expect_error(cs_resolve_line_source(dir), "No shapefile, MapInfo file")
})

