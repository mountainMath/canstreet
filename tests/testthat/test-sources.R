test_that("the manifest is internally consistent", {
  s <- cs_sources()

  expect_gt(nrow(s), 20)
  expect_false(any(duplicated(s$vintage)))
  expect_identical(s$vintage, sort(s$vintage))
  expect_true(all(s$host %in% c("statcan", "abacus")))
  expect_true(all(s$assembly %in% c("single", "tiles")))
  expect_true(all(s$archive %in% c("zip", "exe", "none")))
  expect_true(all(s$coverage %in% c("national", "urban", "bc-urban")))
  expect_true(all(s$product %in% c("AMF", "SNF", "RNF")))

  # An unarchived row is a flat file read directly, which only the AMF is.
  expect_identical(sort(s$vintage[s$archive == "none"]),
                   sort(s$vintage[s$product == "AMF"]))
  expect_true(all(s$crs %in% c(4267L, 4269L, 3347L)))

  # A StatCan row names a file directly; an Abacus row needs a pattern to pick
  # files out of a dataset, and cannot use one without a handle.
  statcan <- s[s$host == "statcan", ]
  expect_true(all(grepl("^https://www12\\.statcan\\.gc\\.ca/", statcan$resource)))
  expect_true(all(grepl("\\.zip$", statcan$resource)))
  expect_true(all(is.na(statcan$file_pattern)))

  abacus <- s[s$host == "abacus", ]
  expect_true(all(grepl("^hdl:", abacus$resource)))
  expect_true(all(!is.na(abacus$file_pattern)))
})

test_that("StatCan URLs follow the projection and directory rules", {
  # Prefix encodes projection, and it flips with the CRS at 2012.
  expect_match(cs_statcan_url(2006), "grnf000r06a_e\\.zip$")
  expect_match(cs_statcan_url(2011), "grnf000r11a_e\\.zip$")
  expect_match(cs_statcan_url(2012), "lrnf000r12a_e\\.zip$")

  # The two vintages that live outside the main directory.
  expect_match(cs_statcan_url(2016), "files-fichiers/2016/lrnf000r16a_e\\.zip$")
  expect_match(cs_statcan_url(2021), "2021/geo/sip-pis/rnf-frr/")

  # 2001 is the one vintage where the `a` variant is not what to take: there it
  # is an ArcInfo coverage, and `m` is the MapInfo release read in its place.
  expect_match(cs_statcan_url(2001), "grnf000r01m_e\\.zip$")
  expect_false(grepl("r01a", cs_statcan_url(2001), fixed = TRUE))

  s <- cs_sources()
  expect_true(all(s$crs[s$host == "statcan" & s$vintage >= 2012] == 3347L))
  expect_true(all(s$crs[s$host == "statcan" & s$vintage <= 2011] == 4269L))
})

test_that("unknown vintages are rejected with a useful message", {
  expect_error(cs_check_vintage(1971), "No road network file")
  expect_error(cs_check_vintage(1971), "Available vintages")
  expect_error(cs_check_vintage(2026), "No road network file")
  expect_error(cs_check_vintage(c(1996, 2021)), "single year")
  expect_identical(cs_check_vintage(2021), 2021L)
  expect_identical(cs_check_vintage("2021"), 2021L)
})

test_that("year ranges collapse for display", {
  expect_equal(cs_collapse_years(c(1991, 1996, 2001, 2005:2007)),
               "1991, 1996, 2001, 2005-2007")
  expect_equal(cs_collapse_years(c(2020, 2021)), "2020, 2021")
  expect_equal(cs_collapse_years(integer(0)), "none")
})

test_that("table names distinguish the products", {
  expect_equal(cs_table_name(1976), "amf_1976")
  expect_equal(cs_table_name(1996), "snf_1996")
  expect_equal(cs_table_name(2021), "rnf_2021")
})

test_that("each vintage is restricted to its own idea of a road", {
  # A Road Network File from 2005 on is roads already.
  expect_null(cs_road_class_sql(2021))
  expect_null(cs_road_class_sql(2006))

  # The Street Network Files keep the unclassed streets, which are the ordinary
  # ones, plus the classes that are also road.
  # The predicate names the labels, not the codes, because that is what import
  # stores -- see `cs_class_domain()`.
  snf <- cs_road_class_sql(1996)
  expect_match(snf, "class IS NULL OR class IN")
  expect_match(snf, "'Highway multiple'", fixed = TRUE)
  expect_false(grepl("'HMU'", snf))
  # watercourses are not among them
  expect_false(grepl("Other Water body", snf, fixed = TRUE))

  # 2001 is the other way round: its line layer carries the census boundary
  # topology, so the filter names what to drop rather than what to keep --
  # everything else, named or not, is road.
  rnf01 <- cs_road_class_sql(2001)
  expect_match(rnf01, "class IS NULL OR class NOT IN")
  expect_true(all(vapply(cs_class_label(2001, cs_rnf_2001_nonroad_classes()),
                         function(k) grepl(paste0("'", k, "'"), rnf01,
                                           fixed = TRUE),
                         logical(1))))
  expect_match(rnf01, "'Neatline'", fixed = TRUE)
  # the streets stay
  expect_false(grepl("Road: n/a, street", rnf01, fixed = TRUE))

  # The Area Master File classes its arterials and highways and leaves the
  # ordinary street unclassed, as the SNF does, but with its own vocabulary.
  amf <- cs_road_class_sql(1976)
  expect_match(amf, "class IS NULL OR class IN")
  expect_true(all(vapply(cs_amf_road_classes(),
                         function(k) grepl(paste0("'", k, "'"), amf),
                         logical(1))))
  expect_false(grepl("'RR'", amf))  # railways are not among them
  expect_identical(cs_road_class_sql(1981), amf)

  # The column is nameable, so the predicate can be applied to an alias.
  expect_match(cs_road_class_sql(2001, "o.class"), "o.class NOT IN")
})
