test_that("every published class code is categorized exactly once", {
  for (v in cs_sources()$vintage) {
    cats <- cs_class_categories(v)
    dom <- cs_class_domain(v)
    if (is.null(cats)) {
      # 2005-2010 carry no class column and document no vocabulary.
      expect_null(dom, info = as.character(v))
      next
    }
    expect_false(anyDuplicated(cats$code) > 0, info = as.character(v))
    expect_true(all(cats$category %in%
                      c("road", "path", "rail", "water", "boundary",
                        "property", "topography", "utility", "other")),
                info = as.character(v))
    expect_true(all(cats$status %in%
                      c("operational", "planned", "under_construction",
                        "unknown")),
                info = as.character(v))
    # The Area Master Files are the one product categorized without a published
    # vocabulary to check against.
    if (!is.null(dom)) expect_setequal(cats$code, dom$code)
  }
})

test_that("the categorization is per vintage, not read across years", {
  # The same word, three different features. 1996's trails are the Bruce Trail
  # and numbered park paths; 2001's are the Klondike and Alaska highways; 2021's
  # "Reserve / Trail" is the forest service road network.
  cat_of <- function(v, code) {
    cats <- cs_class_categories(v)
    cats$category[match(code, cats$code)]
  }
  expect_identical(cat_of(1996, "FTR"), "path")
  expect_identical(cat_of(2001, "1306"), "road")
  expect_identical(cat_of(2021, "26"), "road")

  # Rapid transit is Ottawa's Transitway, a road that carries buses.
  expect_identical(cat_of(2021, "27"), "road")

  # 2016 keeps 95 and 2021 does not, so the categorization follows the domain.
  expect_true("95" %in% cs_class_categories(2016)$code)
  expect_false("95" %in% cs_class_categories(2021)$code)
})

test_that("a road that was not built yet is a road with a status", {
  planned <- function(v) {
    r <- canstreet_road_classes(v)
    r$code[!r$road & r$category == "road"]
  }
  expect_identical(planned(2021), "28")           # Planned
  expect_identical(planned(1996), c("HPR", "HUC"))  # proposed, under construction
  expect_true(all(c("202", "1015") %in% planned(2001)))
  # The Area Master Files have no word for it.
  expect_length(planned(1976), 0L)

  r <- canstreet_road_classes(2021)
  expect_identical(r$status[r$code == "28"], "planned")
  expect_identical(r$category[r$code == "28"], "road")
})

test_that("each vintage is restricted to its own idea of a road", {
  # 2005 to 2010 carry no class column: they are roads already.
  expect_null(cs_road_class_sql(2006))

  # The Street Network Files keep the unclassed streets, which are the ordinary
  # ones, plus the classes that are also road. The predicate names the labels,
  # not the codes, because that is what import stores -- see `cs_class_domain()`.
  snf <- cs_road_class_sql(1996)
  expect_match(snf, "class IS NULL OR class IN")
  expect_match(snf, "'Highway multiple'", fixed = TRUE)
  expect_false(grepl("'HMU'", snf))
  # watercourses are not among them, and neither is the highway that 1996 says
  # is still only proposed
  expect_false(grepl("Other Water body", snf, fixed = TRUE))
  expect_false(grepl("Highway proposed", snf, fixed = TRUE))

  # 2001 is the other way round: its line layer carries the census boundary
  # topology, so the filter names what to drop rather than what to keep --
  # everything else, named or not, is road.
  rnf01 <- cs_road_class_sql(2001)
  expect_match(rnf01, "class IS NULL OR class NOT IN")
  expect_match(rnf01, "'Neatline'", fixed = TRUE)
  expect_match(rnf01, "'Boundary arc'", fixed = TRUE)
  expect_match(rnf01, "'Sub-Block boundary arc'", fixed = TRUE)
  # the streets stay
  expect_false(grepl("Road: n/a, street", rnf01, fixed = TRUE))

  # A modern Road Network File is roads throughout, so the one thing it drops
  # is the road that is not there yet.
  expect_identical(cs_road_class_sql(2021),
                   "(class IS NULL OR class NOT IN ('Planned'))")

  # The Area Master File classes its arterials and highways and leaves the
  # ordinary street unclassed, as the SNF does, but with its own vocabulary.
  amf <- cs_road_class_sql(1976)
  expect_match(amf, "class IS NULL OR class IN")
  expect_true(all(vapply(c("HN", "Z", "BN"),
                         function(k) grepl(paste0("'", k, "'"), amf),
                         logical(1))))
  expect_false(grepl("'RN'", amf))  # railways are not among them
  expect_identical(cs_road_class_sql(1981), amf)

  # The column is nameable, so the predicate can be applied to an alias.
  expect_match(cs_road_class_sql(2001, "o.class"), "o.class NOT IN")
})

test_that("keeping every status leaves a road-only vintage unfiltered", {
  all_st <- c("operational", "planned", "under_construction", "unknown")
  expect_null(cs_road_class_sql(2021, statuses = all_st))
  # 1996 still has watercourses to drop, but now keeps the proposed highway.
  expect_match(cs_road_class_sql(1996, statuses = all_st), "Highway proposed",
               fixed = TRUE)
})

test_that("a multi-vintage filter constrains each vintage to its own rows", {
  one <- cs_roads_only_sql(1996)
  expect_identical(one, cs_road_class_sql(1996))
  expect_false(grepl("vintage", one))

  many <- cs_roads_only_sql(c(1996, 2006, 2021))
  expect_match(many, "vintage <> 1996")
  expect_match(many, "vintage <> 2021")
  # 2006 needs no filter, so it contributes no clause -- and is not excluded by
  # the ones the others contribute.
  expect_false(grepl("vintage <> 2006", many))

  # Nothing to filter at all is no predicate, not an empty string.
  expect_null(cs_roads_only_sql(c(2006, 2007)))
})

test_that("the multi-vintage filter keeps the vintages it does not name", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE TABLE seg (vintage INTEGER, class VARCHAR)")
  DBI::dbExecute(con, paste0(
    "INSERT INTO seg VALUES (1996, 'River'), (1996, 'Highway multiple'),",
    " (1996, NULL), (2006, NULL), (2006, 'anything'),",
    " (2021, 'Planned'), (2021, 'Local')"))

  got <- DBI::dbGetQuery(con, paste0(
    "SELECT vintage, count(*) n FROM seg WHERE ",
    cs_roads_only_sql(c(1996, 2006, 2021)), " GROUP BY 1 ORDER BY 1"))
  expect_identical(got$vintage, c(1996L, 2006L, 2021L))
  expect_identical(as.integer(got$n), c(2L, 2L, 1L))
})

test_that("canstreet_road_classes reports what each vintage keeps", {
  r <- canstreet_road_classes(2021)
  expect_named(r, c("vintage", "code", "label", "category", "status", "road"))
  expect_identical(sum(!r$road), 1L)
  expect_identical(r$label[r$code == "23"], "Local")

  # The Area Master Files have no published labels, so the label is the code.
  amf <- canstreet_road_classes(1976)
  expect_identical(amf$label, amf$code)
  expect_identical(sort(amf$code[amf$road]), c("BN", "HN", "Z"))

  # A vintage with no class column contributes nothing, and an all-empty
  # request still returns the right shape.
  expect_identical(nrow(canstreet_road_classes(2006)), 0L)
  expect_named(canstreet_road_classes(2006),
               c("vintage", "code", "label", "category", "status", "road"))

  expect_true(all(cs_sources()$vintage %in%
                    c(canstreet_road_classes()$vintage, 2005:2010)))
  expect_error(canstreet_road_classes(1900), "No road network file")
})

test_that("a `roads_only` argument resolves to the statuses it keeps", {
  expect_null(cs_roads_only_statuses(FALSE))
  expect_null(cs_roads_only_statuses(NULL))
  expect_identical(cs_roads_only_statuses(TRUE), cs_road_statuses())
  expect_identical(cs_roads_only_statuses(c("operational", "operational")),
                   "operational")

  # Every status a vocabulary uses must be nameable, or the argument cannot
  # reach the classes it is meant to select.
  cats <- do.call(rbind, lapply(cs_sources()$vintage, cs_class_categories))
  expect_true(all(cats$status %in% cs_class_statuses()))

  expect_error(cs_roads_only_statuses("built"), "Unknown build status")
  expect_error(cs_roads_only_statuses("built"), "canstreet_road_classes")
  expect_error(cs_roads_only_statuses(character(0)), "must be TRUE, FALSE")
  expect_error(cs_roads_only_statuses(NA_character_), "must be TRUE, FALSE")
  expect_error(cs_roads_only_statuses(1), "must be TRUE, FALSE")
})

test_that("widening the statuses keeps the roads that were not yet built", {
  # 2021's only non-road class is Planned, so naming it leaves nothing to drop.
  expect_identical(cs_road_class_sql(2021),
                   "(class IS NULL OR class NOT IN ('Planned'))")
  expect_null(cs_road_class_sql(2021, statuses = cs_class_statuses()))

  # The SNF filter names what to keep, so widening adds to the list rather than
  # shortening it -- 1996's "Highway proposed" is the arcs of Highway 407.
  narrow <- cs_road_class_sql(1996)
  wide <- cs_road_class_sql(1996, statuses = c(cs_road_statuses(), "planned"))
  expect_false(grepl("Highway proposed", narrow, fixed = TRUE))
  expect_true(grepl("Highway proposed", wide, fixed = TRUE))

  # And it travels through the multi-vintage form.
  expect_false(grepl("Planned",
                     cs_roads_only_sql(c(1996, 2021),
                                       statuses = cs_class_statuses()),
                     fixed = TRUE))
})
