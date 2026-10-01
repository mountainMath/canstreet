test_that("the manifest is internally consistent", {
  s <- cs_sources()

  expect_gt(nrow(s), 20)
  expect_false(any(duplicated(s$vintage)))
  expect_identical(s$vintage, sort(s$vintage))
  expect_true(all(s$host %in% c("statcan", "abacus", "mountainmath")))
  expect_true(all(s$assembly %in% c("single", "tiles")))
  expect_true(all(s$archive %in% c("zip", "exe")))
  expect_true(all(s$coverage %in% c("national", "urban")))
  expect_true(all(s$product %in% c("AMF", "SNF", "RNF")))

  # The Area Master Files are the four censuses before the Street Network
  # File, each one archive of flat files in NAD27.
  amf <- s[s$product == "AMF", ]
  expect_identical(amf$vintage, c(1971L, 1976L, 1981L, 1986L))
  expect_true(all(amf$crs == 4267L))
  expect_true(all(amf$assembly == "single"))
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
  expect_identical(abacus$vintage, c(1991L, 1996L))

  # What Statistics Canada no longer serves is hosted as one zip per census,
  # named for the table it becomes.
  hosted <- s[s$host == "mountainmath", ]
  expect_identical(hosted$vintage, amf$vintage)
  expect_identical(basename(hosted$resource),
                   paste0(vapply(hosted$vintage, cs_table_name, character(1)),
                          ".zip"))
  expect_true(all(grepl("^https://", hosted$resource)))
  expect_true(all(hosted$archive == "zip"))
  expect_true(all(is.na(hosted$file_pattern)))
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
  expect_error(cs_check_vintage(1966), "No road network file")
  expect_error(cs_check_vintage(1966), "Available vintages")
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
  expect_equal(cs_table_name(1971), "amf_1971")
  expect_equal(cs_table_name(1986), "amf_1986")
  expect_equal(cs_table_name(1996), "snf_1996")
  expect_equal(cs_table_name(2021), "rnf_2021")
})
