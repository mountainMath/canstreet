test_that("every published domain is a legal ENUM vocabulary", {
  for (v in cs_sources()$vintage) {
    for (d in list(cs_class_domain(v), cs_rank_domain(v))) {
      if (is.null(d)) next
      expect_false(anyDuplicated(d$code) > 0, label = paste("codes", v))
      # The reason `cs_domain_disambiguate()` exists: DuckDB refuses an ENUM
      # that carries the same value twice.
      expect_false(anyDuplicated(d$label) > 0, label = paste("labels", v))
      expect_true(all(nzchar(d$code) & nzchar(d$label)))
    }
  }
})

test_that("the vocabularies are per-vintage, not shared across the era", {
  c11 <- cs_class_domain(2011)$code
  c16 <- cs_class_domain(2016)$code
  c21 <- cs_class_domain(2021)$code

  # 2016 defines 95 as a second "Unknown"; 2021 retires it and adds 87 for
  # winter roads. 2011 has neither.
  expect_false(any(c("87", "95") %in% c11))
  expect_true("95" %in% c16)
  expect_false("87" %in% c16)
  expect_true("87" %in% c21)
  expect_false("95" %in% c21)

  # The colliding pair keeps both published labels, told apart by code.
  d16 <- cs_class_domain(2016)
  expect_identical(sort(d16$label[d16$code %in% c("90", "95")]),
                   c("Unknown (90)", "Unknown (95)"))

  # 2001 is a different vocabulary entirely, not an earlier version of this one.
  expect_length(intersect(cs_class_domain(2001)$code, c21), 0L)
  expect_identical(cs_class_label(2001, "1536"), "Neatline")

  # The Street Network Files classify features, not roads.
  expect_identical(cs_class_label(1996, "CEA"), "Enumeration Area Boundary")
  expect_identical(cs_class_label(1991, "W"),
                   "Other Water body defined using streamline")

  # The Area Master Files take their labels from the feature-type and sub-type
  # columns of the same List A, in that guide's AMF-format variant.
  expect_identical(cs_class_label(1976, "HN"), "Highway")
  expect_identical(cs_class_label(1981, "GB"), "Property boundary")
  expect_identical(cs_class_domain(1976), cs_class_domain(1981))
  # `OB` is not a List A combination and `Z` contradicts the one it names, so
  # neither is labelled.
  expect_false(any(c("OB", "Z") %in% cs_class_domain(1976)$code))

  # And these have no published vocabulary at all.
  expect_null(cs_class_domain(2006))
  expect_null(cs_rank_domain(2006))
  expect_null(cs_rank_domain(1996))
})

test_that("a code with no published label translates to itself", {
  expect_identical(cs_class_label(1976, c("HN", "Z")), c("Highway", "Z"))
  expect_identical(cs_class_label(2021, "not-a-code"), "not-a-code")
  expect_identical(cs_class_label(2021, c("23", "not-a-code")),
                   c("Local", "not-a-code"))
})

test_that("canstreet_domains() reports what is stored", {
  all <- canstreet_domains()
  expect_s3_class(all, "tbl_df")
  expect_named(all, c("vintage", "domain", "code", "label"))
  expect_setequal(unique(all$domain), c("class", "rank"))
  expect_false(2006L %in% all$vintage)
  expect_true(all(c(1976L, 1981L) %in% all$vintage))

  expect_identical(nrow(canstreet_domains(2006)), 0L)
  expect_setequal(unique(canstreet_domains(2016, domain = "class")$domain),
                  "class")
  expect_identical(nrow(canstreet_domains(2021, domain = "rank")), 5L)
})

# A vintage table carrying one published class, one published rank, a code the
# guide does not define, and a NULL -- which is every case the retyping has to
# get right at once.
local_labelled_table <- function(vintage = 2016, env = parent.frame()) {
  cache <- local_cache(env)
  con <- cs_connect(cache, read_only = FALSE)
  cs_meta_init(con)
  table <- cs_table_name(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  DBI::dbExecute(con, paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(con, table),
    " (vintage, source_file, source_id, name, class, rank, len_m, geom)",
    " VALUES\n",
    "(", vintage, ", 'fx', '1', 'A', '23', '5', 1, st_geomfromtext('LINESTRING(0 0, 1 0)')),\n",
    "(", vintage, ", 'fx', '2', 'B', '10', '1', 1, st_geomfromtext('LINESTRING(0 1, 1 1)')),\n",
    "(", vintage, ", 'fx', '3', 'C', '95', '3', 1, st_geomfromtext('LINESTRING(0 2, 1 2)')),\n",
    "(", vintage, ", 'fx', '4', 'D', 'ZZ', NULL, 1, st_geomfromtext('LINESTRING(0 3, 1 3)')),\n",
    "(", vintage, ", 'fx', '5', 'E', NULL, NULL, 1, st_geomfromtext('LINESTRING(0 4, 1 4)'));"))
  list(cache = cache, con = con, table = table, vintage = vintage)
}

test_that("import retypes class and rank as labelled ENUMs", {
  fx <- local_labelled_table()
  expect_identical(cs_label_vintage(fx$con, fx$table, fx$vintage),
                   c("class", "rank"))

  got <- DBI::dbGetQuery(fx$con, paste0(
    "SELECT source_id, class, rank FROM ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " ORDER BY source_id"))
  expect_s3_class(got$class, "factor")
  expect_identical(as.character(got$class),
                   c("Local", "Highway", "Unknown (95)", "ZZ", NA))
  expect_identical(as.character(got$rank),
                   c("All other streets (not rank 1, 2, 3, or 4)",
                     "Trans-Canada Highway", "Major Highway (not rank 1 or 2)",
                     NA, NA))

  # The declared type is the whole published vocabulary, not just the codes that
  # occur, plus anything observed the guide does not define.
  levs <- levels(got$class)
  expect_true(all(cs_class_domain(2016)$label %in% levs))
  expect_true("ZZ" %in% levs)
  expect_identical(levs[length(levs)], "ZZ")

  # Ranks are ordinal, and the ENUM is declared in rank order.
  ord <- DBI::dbGetQuery(fx$con, paste0(
    "SELECT rank FROM ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " WHERE rank IS NOT NULL ORDER BY rank"))$rank
  expect_identical(as.character(ord)[1], "Trans-Canada Highway")
})

test_that("labelling is idempotent and leaves an unlabellable vintage alone", {
  fx <- local_labelled_table(2006)
  expect_identical(cs_label_vintage(fx$con, fx$table, 2006), character(0))
  got <- DBI::dbGetQuery(fx$con, paste0(
    "SELECT typeof(class) t FROM ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " LIMIT 1"))$t
  expect_identical(got, "VARCHAR")
})

test_that("the segments view still unions a labelled and an unlabelled table", {
  fx <- local_labelled_table(2016)
  cs_label_vintage(fx$con, fx$table, 2016)
  cs_meta_write(fx$con, 2016, list(schema_version = cs_schema_version()))

  t76 <- cs_table_name(1976)
  DBI::dbExecute(fx$con, cs_create_table_sql(fx$con, t76))
  DBI::dbExecute(fx$con, paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(fx$con, t76),
    " (vintage, source_file, source_id, class, len_m, geom) VALUES",
    " (1976, 'fx', '1', 'HN', 1, st_geomfromtext('LINESTRING(0 0, 1 0)'));"))
  cs_meta_write(fx$con, 1976, list(schema_version = cs_schema_version()))
  cs_rebuild_segments_view(fx$con)

  got <- DBI::dbGetQuery(fx$con,
    "SELECT vintage, class, typeof(class) t FROM segments ORDER BY vintage, class")
  expect_identical(unique(got$t), "VARCHAR")
  expect_true("HN" %in% got$class)
  expect_true("Highway" %in% got$class)
})

test_that("the road-class filter selects on the labels that were stored", {
  fx <- local_labelled_table(1996)
  cs_label_vintage(fx$con, fx$table, 1996)
  # 1996's fixture rows carry modern codes, which its own vocabulary does not
  # define, so they survive as codes -- and the filter must not match them.
  keep <- DBI::dbGetQuery(fx$con, paste0(
    "SELECT count(*) n FROM ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " WHERE ", cs_road_class_sql(1996)))$n
  expect_identical(as.integer(keep), 1L)  # only the NULL-class row

  DBI::dbExecute(fx$con, paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " (vintage, source_file, source_id, class, len_m, geom) VALUES",
    " (1996, 'fx', '9', 'Highway multiple', 1,",
    "  st_geomfromtext('LINESTRING(0 9, 1 9)'));"))
  keep <- DBI::dbGetQuery(fx$con, paste0(
    "SELECT count(*) n FROM ", DBI::dbQuoteIdentifier(fx$con, fx$table),
    " WHERE ", cs_road_class_sql(1996)))$n
  expect_identical(as.integer(keep), 2L)
})
