amf_layouts <- c("wide", "text", "packed")

test_that("all three Area Master File layouts parse to the same answer", {
  dir <- withr::local_tempdir()

  for (layout in amf_layouts) {
    path <- write_fixture_amf(dir, layout)
    n <- cs_amf_nodes(path)

    # Headers are not nodes; every detail record that is not a feature header
    # is. The layout is read off the file, and nothing in it went unread.
    expect_identical(nrow(n), 17L, label = layout)
    expect_identical(attr(n, "amf_layout"), layout, label = layout)
    expect_identical(attr(n, "amf_unreadable"), 0L, label = layout)

    # The heading scopes the zone -- written `10 ` in one file and ` 10` in
    # another -- and the municipality record names the subdivision.
    expect_identical(unique(n$zone), 10L, label = layout)
    expect_identical(unique(n$sheet), c(1L, 2L), label = layout)
    expect_identical(unique(n$area_name), c("VANCOUVER", "BURNABY"),
                     label = layout)

    # Name, type and direction carry down from the feature header onto its
    # nodes, and the class is the node's own.
    main <- n[n$sheet == 1L & n$feature == 1200L, ]
    expect_identical(unique(main$name), "MAIN", label = layout)
    expect_identical(unique(main$type), "ST", label = layout)
    expect_true(all(is.na(main$dir)), label = layout)
    expect_true(all(is.na(main$class)), label = layout)
    hwy <- n[n$feature == 1500L, ]
    expect_identical(unique(hwy$class), "HN", label = layout)
    expect_identical(unique(hwy$type), "HY", label = layout)
    expect_identical(unique(hwy$dir), "E", label = layout)

    # Coordinates decode in every layout, and the blank field is not a zero.
    expect_identical(main$x, c(425833, 425933, 426033), label = layout)
    expect_identical(unique(main$y), 5458561, label = layout)
    expect_identical(sum(is.na(n$x)), 1L, label = layout)
    expect_identical(sum(is.na(n$ref_l_x)), 1L, label = layout)

    # The out-of-order feature comes back in sequence order.
    oak <- n[n$feature == 1300L, ]
    expect_identical(oak$seq_no, c(10L, 20L, 40L, 50L), label = layout)

    segs <- cs_amf_segments(n)
    expect_identical(nrow(segs), 7L, label = layout)

    # A chain of three nodes is two segments; a missing or repeated coordinate
    # makes none; an `E` followed by a `B` is not bridged.
    expect_identical(as.integer(table(segs$name)[["MAIN"]]), 3L, label = layout)
    expect_identical(as.integer(table(segs$name)[["OAK"]]), 2L, label = layout)
    expect_false("CAMBIE" %in% segs$name, label = layout)

    # Addresses: `from` at the node the segment starts at, `to` at the node it
    # ends at.
    m <- segs[segs$name == "MAIN" & segs$sheet == 1L, ]
    expect_identical(m$af_l, c(100L, 200L), label = layout)
    expect_identical(m$at_l, c(198L, 298L), label = layout)
    expect_identical(m$af_r, c(101L, 201L), label = layout)
    expect_identical(m$at_r, c(199L, 299L), label = layout)

    # The heading is part of the identifier, so the two headings' identically
    # numbered features do not collide. The feature code is a number whichever
    # side of its field it was written on.
    expect_identical(anyDuplicated(segs$source_id), 0L, label = layout)
    expect_match(segs$source_id[1], "^01-5937-1522-001200-010$")

    # Zone 10 is NAD27 UTM zone 10.
    expect_identical(unique(segs$epsg), 26710L, label = layout)

    # The node view keeps what the segment view collapses.
    expect_identical(main$ref_l_x, main$x - 40, label = layout)
    expect_identical(main$ref_r_y, main$y + 40, label = layout)
    expect_identical(unique(n$xref_area), "1522", label = layout)
    expect_identical(unique(n$xref_name), "CROSS", label = layout)
    expect_identical(unique(n$xref_type), "ST", label = layout)
    expect_match(segs$wkt[1], "^LINESTRING\\(425833 5458561, 425933 5458561\\)$")
  }
})

test_that("read_amf returns segments in the storage projection", {
  dir <- withr::local_tempdir()
  paths <- vapply(amf_layouts, function(l) write_fixture_amf(dir, l),
                  character(1))
  a <- read_amf(paths[["wide"]])

  expect_s3_class(a, "sf")
  expect_identical(sf::st_crs(a), sf::st_crs(3347))
  expect_identical(nrow(a), 7L)
  expect_identical(as.character(unique(sf::st_geometry_type(a))), "LINESTRING")

  # 100 m in UTM is 100 m in Lambert to within the scale factor.
  expect_equal(as.numeric(sf::st_length(a)), rep(100, 7), tolerance = 0.01)

  # The three layouts hold the same network, so they must produce the same
  # table.
  for (layout in c("text", "packed")) {
    b <- read_amf(paths[[layout]])
    expect_equal(sf::st_drop_geometry(a), sf::st_drop_geometry(b),
                 label = layout)
    expect_equal(sf::st_coordinates(a), sf::st_coordinates(b), label = layout)
  }

  # The node view is the file as it stores it.
  expect_identical(nrow(read_amf(paths[["wide"]], nodes = TRUE)), 17L)
  expect_false(inherits(read_amf(paths[["wide"]], nodes = TRUE), "sf"))
})

test_that("the layout is read off the coordinates, not the record width", {
  dir <- withr::local_tempdir()
  for (layout in amf_layouts) {
    path <- write_fixture_amf(dir, layout)
    bytes <- readBin(path, "raw", n = file.info(path)$size)
    lines <- cs_amf_record_bounds(bytes, rejoin = FALSE)
    expect_identical(cs_amf_detect_layout(bytes, lines), layout)
  }

  # A file whose cross-street fields are blank throughout is narrower than its
  # layout, because trailing blanks are stripped. It is still that layout.
  w <- amf_writer("wide")
  narrow <- function(...) {
    r <- w$node(...)
    r[w$layout$xr_area[1]:w$layout$width] <- 0x20L
    r
  }
  path <- w$write(list(
    w$heading(10L, "NARROW"), w$muni("1522", "VANCOUVER"),
    w$header("1522", 1000L, "MAIN"),
    narrow("1522", 1000L, 10L, 425833L, 5458561L, chain = "B"),
    narrow("1522", 1000L, 20L, 425933L, 5458561L, chain = "E")),
    file.path(dir, "narrow.txt"))
  n <- cs_amf_nodes(path)
  expect_identical(attr(n, "amf_layout"), "wide")
  expect_identical(n$x, c(425833, 425933))
  expect_true(all(is.na(n$xref_name)))
})

test_that("packed decimal decodes, and refuses what is not a number", {
  # 0425833 packed is 0x04 0x25 0x83 0x3C -- and its second byte is EBCDIC for
  # a newline, which is the reason records cannot simply be split on one.
  m <- matrix(as.raw(vapply(amf_pack(425833L), identity, integer(1))), ncol = 1)
  expect_identical(cs_amf_unpack_comp3(m, 1L, 4L), 425833)

  # A run of EBCDIC blanks is the "no coordinate" sentinel: sign nibble 0.
  blank <- matrix(as.raw(rep(0x20, 4)), ncol = 1)
  expect_identical(cs_amf_unpack_comp3(blank, 1L, 4L), NA_real_)
})

test_that("a record torn apart by a packed newline is put back together", {
  dir <- withr::local_tempdir()
  path <- write_fixture_amf(dir, "packed")
  bytes <- readBin(path, "raw", n = file.info(path)$size)

  # The fixture's first easting packs to a byte that is a newline, so the file
  # holds more newlines than records.
  expect_gt(sum(bytes == as.raw(0x0a)), length(cs_amf_record_bounds(bytes)$start))

  # Rejoined, no record is wider than the layout.
  b <- cs_amf_record_bounds(bytes)
  expect_lte(max(b$end - b$start + 1L), 95L)

  # A text file is cut on its line ends and loses the carriage return.
  path <- write_fixture_amf(dir, "wide")
  bytes <- readBin(path, "raw", n = file.info(path)$size)
  b <- cs_amf_record_bounds(bytes, rejoin = FALSE)
  expect_identical(length(b$start), sum(bytes == as.raw(0x0a)))
  expect_false(any(bytes[b$end] == as.raw(0x0d)))
  expect_lte(max(b$end - b$start + 1L), 119L)
})

test_that("record types survive what the national files do to them", {
  dir <- withr::local_tempdir()
  w <- amf_writer("wide")
  node <- w$node

  # The first record is the heading even with part of the name written over
  # its municipality columns, as in Kingston Township 1976.
  heading <- w$heading(18L, "KINGSTON TP")
  heading[5:8] <- utf8ToInt("STON")
  # A municipality record whose count fills the feature-code columns, as in
  # Stoney Creek 1986, is still a municipality record.
  recs <- list(
    heading,
    w$muni("0514", "KINGSTON TP", count = "123456"),
    w$header("0514", 1000L, "PRINCESS"),
    node("0514", 1000L, 10L, 380000L, 4900000L, chain = "B"),
    # Keyed in a later update under somebody else's metropolitan area code:
    # read off the record it would break the chain in two places.
    node("0514", 1000L, 20L, 380100L, 4900000L, rec_cma = "2406"),
    node("0514", 1000L, 30L, 380200L, 4900000L, chain = "E"),
    w$header("0514", 1100L, "DIVISION"),
    node("0514", 1100L, 10L, 380000L, 4900200L, chain = "B"),
    node("0514", 1100L, 20L, 380100L, 4900200L),
    node("0514", 1100L, 30L, 380200L, 4900200L, chain = "E"))
  # First eight bytes overwritten with a name, as in St. Catharines 1976: the
  # record takes the codes of the one before it.
  recs[[9]][1:8] <- utf8ToInt("PELHAM  ")

  n <- cs_amf_nodes(w$write(recs, file.path(dir, "kingston.txt")))
  expect_identical(nrow(n), 6L)
  expect_identical(attr(n, "amf_unreadable"), 0L)
  expect_identical(unique(n$zone), 18L)
  expect_identical(unique(n$area_name), "KINGSTON TP")
  expect_identical(unique(n$cma), "5937")
  expect_identical(unique(n$area), "0514")
  expect_identical(n$feature, rep(c(1000L, 1100L), each = 3L))

  segs <- cs_amf_segments(n)
  expect_identical(nrow(segs), 4L)
  expect_identical(as.integer(table(segs$name)), c(2L, 2L))
})

# Put a feature header through the conversion meant for detail records, the way
# nineteen of the 1981 files were: columns 32-39 of the name read as two packed
# coordinates and printed as `       .`, and what followed copied as four
# five-character fields, each left-justified.
amf_damage <- function(rec) {
  tail <- vapply(0:3, function(k) {
    f <- trimws(intToUtf8(rec[40:44 + 5L * k]))
    formatC(f, width = -5L)
  }, character(1))
  rec[32:47] <- utf8ToInt("       .       .")
  rec[48:67] <- utf8ToInt(paste(tail, collapse = ""))
  rec
}

test_that("a damaged feature header keeps its type and direction", {
  dir <- withr::local_tempdir()
  w <- amf_writer("wide", cma = "4602")
  feat <- function(feature, name, type, dir, y, damaged = TRUE) {
    h <- w$header("0010", feature, name, type = type, dir = dir)
    list(if (damaged) amf_damage(h) else h,
         w$node("0010", feature, 10L, 630000L, y, chain = "B"),
         w$node("0010", feature, 20L, 630100L, y, chain = "E"))
  }
  recs <- c(
    list(w$heading(14L, "WINNIPEG"), w$muni("0010", "WINNIPEG")),
    feat(1000L, "MAIN", "ST", "", 5527000L),
    feat(1100L, "PORTAGE", "AV", "E", 5527100L),
    feat(1200L, "ST MARYS", "RD", "SW", 5527200L),
    # A name that runs to the end of its field ahead of the type.
    feat(1300L, "ASSINIBOINE PARK WIS", "ST", "", 5527300L),
    # A twenty-character name with no type leaves its last two characters
    # where a type would be; `TS` is not a street type and is not kept.
    feat(1400L, "WINNIPEG CITY LIMITS", "", "", 5527400L),
    feat(1500L, "BROADWAY", "AV", "", 5527500L, damaged = FALSE))

  segs <- cs_amf_segments(cs_amf_nodes(
    w$write(recs, file.path(dir, "winnipeg.txt"))))
  expect_identical(nrow(segs), 6L)

  # The name is not a name any more, and is missing rather than guessed at.
  expect_identical(segs$name, c(rep(NA_character_, 5L), "BROADWAY"))
  expect_identical(segs$type, c("ST", "AV", "RD", "ST", NA, "AV"))
  expect_identical(segs$dir, c(NA, "E", "SW", NA, NA, NA))
  # Geometry is untouched.
  expect_match(segs$wkt[1], "^LINESTRING\\(630000 5527000, 630100 5527000\\)$")
  expect_identical(unique(segs$epsg), 26714L)
})

test_that("an alias is not a street, and a class is a class in either case", {
  dir <- withr::local_tempdir()
  w <- amf_writer("wide")
  recs <- list(
    w$heading(10L, "FIXTURE"), w$muni("1522", "VANCOUVER"),
    # Three 1986 features are typed `e` for `E`.
    w$header("1522", 1000L, "KINGSWAY", type = "BV"),
    w$node("1522", 1000L, 10L, 425000L, 5458561L, chain = "B", class = "e"),
    w$node("1522", 1000L, 20L, 425100L, 5458561L, chain = "E", class = "e"),
    # An alias carries the original feature's name where a node would be.
    w$header("1522", 1100L, "HIGHWAY 1A"),
    amf_rec(119L, list(1L, "5937"), list(5L, "1522"), list(9L, "1100  "),
            list(15L, "010"), list(18L, "DA"), list(27L, "KINGSWAY")),
    # A coordinate that is not a number is no coordinate.
    w$header("1522", 1200L, "FRASER"),
    w$node("1522", 1200L, 10L, 425000L, 5458761L, chain = "B"),
    w$node("1522", 1200L, 20L, 425100L, 5458761L, chain = "E"))
  recs[[9]][32:39] <- utf8ToInt("0042510A")

  n <- cs_amf_nodes(w$write(recs, file.path(dir, "alias.txt")))
  expect_identical(nrow(n), 4L)
  expect_identical(unique(n$class[n$feature == 1000L]), "E")
  expect_false(1100L %in% n$feature)
  expect_identical(n$x[n$feature == 1200L], c(NA, 425100))
  expect_identical(nrow(cs_amf_segments(n)), 1L)
})

test_that("a file that is not an Area Master File is refused", {
  dir <- withr::local_tempdir()

  empty <- file.path(dir, "empty.data")
  file.create(empty)
  expect_error(cs_amf_nodes(empty), "empty")

  wide <- file.path(dir, "wide.data")
  writeLines(paste0("1234", strrep("x", 200)), wide)
  expect_error(cs_amf_nodes(wide), "not one of them")

  expect_error(read_amf(file.path(dir, "nope.data")), "one existing")
  expect_error(cs_amf_layout("csv"), "Unknown Area Master File layout")
})
