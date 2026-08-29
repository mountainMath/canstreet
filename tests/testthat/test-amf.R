test_that("both Area Master File layouts parse to the same answer", {
  dir <- withr::local_tempdir()

  for (packed in c(FALSE, TRUE)) {
    path <- write_fixture_amf(dir, packed)
    n <- cs_amf_nodes(path)
    label <- if (packed) "1981" else "1976"

    # Headers are not nodes; every detail record that is not a feature header
    # is.
    expect_identical(nrow(n), 17L, label = label)
    expect_identical(attr(n, "amf_packed"), packed, label = label)

    # The map sheet scopes the zone and the area header names the subdivision.
    expect_identical(unique(n$zone), 10L, label = label)
    expect_identical(unique(n$sheet), c(1L, 2L), label = label)
    expect_identical(unique(n$area_name), c("VANCOUVER", "BURNABY"),
                     label = label)

    # Name, type and class carry down from the feature header onto its nodes.
    main <- n[n$sheet == 1L & n$feature == 12L, ]
    expect_identical(unique(main$name), "MAIN", label = label)
    expect_identical(unique(main$type), "ST", label = label)
    expect_true(all(is.na(main$class)), label = label)
    expect_identical(unique(n$class[n$feature == 15L]), "HN", label = label)

    # Coordinates decode in either layout, and the blank field is not a zero.
    expect_identical(main$x, c(425833, 425933, 426033), label = label)
    expect_identical(unique(main$y), 5458561, label = label)
    expect_identical(sum(is.na(n$x)), 1L, label = label)

    # The out-of-order feature comes back in sequence order.
    oak <- n[n$feature == 13L, ]
    expect_identical(oak$seq_no, c(10L, 20L, 40L, 50L), label = label)

    segs <- cs_amf_segments(n)
    expect_identical(nrow(segs), 7L, label = label)

    # A chain of three nodes is two segments; a missing or repeated coordinate
    # makes none; an `E` followed by a `B` is not bridged.
    expect_identical(as.integer(table(segs$name)[["MAIN"]]), 3L, label = label)
    expect_identical(as.integer(table(segs$name)[["OAK"]]), 2L, label = label)
    expect_false("CAMBIE" %in% segs$name, label = label)

    # Addresses: `from` at the node the segment starts at, `to` at the node it
    # ends at.
    m <- segs[segs$name == "MAIN" & segs$sheet == 1L, ]
    expect_identical(m$af_l, c(100L, 200L), label = label)
    expect_identical(m$at_l, c(198L, 298L), label = label)
    expect_identical(m$af_r, c(101L, 201L), label = label)
    expect_identical(m$at_r, c(199L, 299L), label = label)

    # The sheet is part of the identifier, so the two sheets' identically
    # numbered features do not collide.
    expect_identical(anyDuplicated(segs$source_id), 0L, label = label)
    expect_match(segs$source_id[1], "^01-9330-5915-000012-010$")

    # Zone 10 is NAD27 UTM zone 10.
    expect_identical(unique(segs$epsg), 26710L, label = label)

    # The node view keeps what the segment view collapses.
    expect_identical(main$ref_l_x, main$x - 40, label = label)
    expect_identical(main$ref_r_y, main$y + 40, label = label)
    expect_identical(unique(n$xref_name), "CROSS", label = label)
    expect_identical(unique(n$xref_type), "ST", label = label)
    expect_match(segs$wkt[1], "^LINESTRING\\(425833 5458561, 425933 5458561\\)$")
  }
})

test_that("read_amf returns segments in the storage projection", {
  dir <- withr::local_tempdir()
  a <- read_amf(write_fixture_amf(dir, FALSE))
  b <- read_amf(write_fixture_amf(dir, TRUE))

  expect_s3_class(a, "sf")
  expect_identical(sf::st_crs(a), sf::st_crs(3347))
  expect_identical(nrow(a), 7L)
  expect_identical(as.character(unique(sf::st_geometry_type(a))), "LINESTRING")

  # 100 m in UTM is 100 m in Lambert to within the scale factor.
  expect_equal(as.numeric(sf::st_length(a)), rep(100, 7), tolerance = 0.01)

  # The two layouts hold the same network, so they must produce the same table.
  expect_equal(sf::st_drop_geometry(a), sf::st_drop_geometry(b))
  expect_equal(sf::st_coordinates(a), sf::st_coordinates(b))

  # The node view is the file as it stores it.
  expect_identical(nrow(read_amf(a_path <- write_fixture_amf(dir, FALSE),
                                 nodes = TRUE)), 17L)
  expect_false(inherits(read_amf(a_path, nodes = TRUE), "sf"))
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
  path <- write_fixture_amf(dir, TRUE)
  bytes <- readBin(path, "raw", n = file.info(path)$size)

  # The fixture's first easting packs to a byte that is a newline, so the file
  # holds more newlines than records.
  expect_gt(sum(bytes == as.raw(0x0a)), length(cs_amf_record_bounds(bytes)$start))

  # Rejoined, no record is wider than the layout.
  b <- cs_amf_record_bounds(bytes)
  expect_lte(max(b$end - b$start + 1L), 95L)
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
})
