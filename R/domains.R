# Attribute domains -----------------------------------------------------------
#
# `class` and `rank` are coded fields, and the codes are meaningless without the
# vocabulary that defines them. Statistics Canada publishes that vocabulary once
# per census year, and it changes: 2016 adds class 95 to mean the same thing as
# 90, 2021 drops 95 and adds 87 for winter roads, and the pre-2005 products use
# vocabularies with no codes in common with the modern one at all. So a domain
# here is always tied to the vintages it was published for, never shared across
# an era boundary on the assumption that the codes carried over.
#
# Where each domain comes from, all of them primary sources rather than
# secondary documentation:
#
#   1991, 1996  "List A: Feature Classification" in the Street Network File User
#               Guide (`snfarc.pdf`), which the Abacus deposit ships alongside
#               the shapefiles.
#   2001        Section 5, "Class", of the 2001 Road Network Files Reference
#               Guide, catalogue 92F0157GIE, shipped inside `grnf000r01a_e.zip`.
#   2011        Tables under RANK and CLASS in the Road Network File Reference
#               Guide 2011, catalogue 92-500-G, shipped inside the zip.
#   2016        The same tables in the 2016 guide, shipped inside the zip. It is
#               the only source that documents class 95.
#   2021        https://www12.statcan.gc.ca/census-recensement/2021/geo/ref/
#               domain-domaine/index2021-eng.cfm?lang=e&id=CLASS (and `=RANK`).
#
# 2005 through 2010 get no domain: the 2006 reference guide documents no CLASS
# or RANK table, and the 2006 file carries neither column. The Area Master
# Files get none either -- see `cs_amf_road_classes()` for why the 1991 guide's
# List A cannot simply be reused for them.

#' The 1991 and 1996 Street Network File feature classification
#'
#' List A of the Street Network File User Guide, verbatim. A blank `class` --
#' stored as `NULL` -- is not an absence of information here: the guide gives it
#' its own row, "Addressable Single street & public access lane", which is why
#' the ordinary street is the unclassed value in these two vintages.
#'
#' @return A tibble of `code` and `label`.
#' @keywords internal
#' @noRd
cs_domain_snf_class <- function() {
  tibble::tribble(
    ~code,  ~label,
    "E",    "Addressable Multiple street & public access lane",
    "HSI",  "Highway single",
    "HMU",  "Highway multiple",
    "HPR",  "Highway proposed",
    "HUC",  "Highway under construction",
    "H",    "Other Highway",
    "BSI",  "Bridge or Tunnel - Single Highway or Addressable Multiple street",
    "BMU",  "Bridge or Tunnel - Multiple Highway",
    "BMN",  "Bridge or Tunnel Addressable Single street",
    "B",    "Other Bridge or Tunnel",
    "RSI",  "Railway single track",
    "RMU",  "Railway multiple track",
    "RSG",  "Railway siding or yard",
    "R",    "Other Railway features",
    "FRA",  "Ramp",
    "FTR",  "Trail",
    "FWA",  "Walkway",
    "FEX",  "Feature extension",
    "F",    "Other Roadway Associated features",
    "WCR",  "Creek - defined using streamline",
    "WAQ",  "Aqueduct",
    "WCA",  "Canal",
    "WRI",  "River",
    "W",    "Other Water body defined using streamline",
    "SCR",  "Creek - defined using shoreline",
    "SAQ",  "Aqueduct",
    "SCA",  "Canal",
    "SRI",  "River",
    "SLA",  "Lake",
    "SPO",  "Pond",
    "SRE",  "Reservoir",
    "SOC",  "Ocean",
    "S",    "Other Waterbody defined using shorelines",
    "IFA",  "Falls",
    "IDA",  "Dam",
    "I",    "Other Associated features",
    "MMU",  "Municipal Boundary",
    "MPR",  "Provincial Boundary",
    "MNA",  "National Boundary",
    "MFE",  "Federal Electoral District Boundary",
    "M",    "Other Political boundaries",
    "CEA",  "Enumeration Area Boundary",
    "C",    "Other Geostatistical area boundaries",
    "GPA",  "Park Boundary",
    "GGO",  "Golf Boundary",
    "GAI",  "Airport Boundary",
    "GHO",  "Hospital Boundary",
    "GSH",  "Shopping Centre Boundary",
    "GSC",  "School Boundary",
    "GCO",  "College Boundary",
    "GUN",  "University Boundary",
    "GJA",  "Jail Boundary",
    "GCH",  "Church Boundary",
    "GGT",  "Government Boundary",
    "G",    "Other Property boundaries",
    "U",    "Other Urban-Rural boundaries",
    "PPA",  "Park",
    "PGO",  "Golf",
    "PHO",  "Hospital",
    "PAI",  "Airport",
    "PSH",  "Shopping centre",
    "PSC",  "School",
    "PCO",  "College",
    "PUN",  "University",
    "PJA",  "Jail",
    "PCH",  "Church",
    "PGT",  "Government",
    "P",    "Other Point features",
    "OFA",  "Cliff",
    "ODI",  "Ditch",
    "O",    "Other Topography features",
    "ZHY",  "Hydroline (Major)",
    "ZTE",  "Telephone line (Major)",
    "ZFE",  "Fence",
    "ZPI",  "Pipeline",
    "Z",    "Other features",
    "D",    "Alias features"
  )
}

#' The 2001 Road Network File class vocabulary
#'
#' Section 5 of the 2001 reference guide, verbatim. The composite descriptions
#' read "lanes, surface type, division, relief, status, surface" -- so `1011`,
#' the ordinary street and 688,063 of the file's arcs, is "Road: n/a, street,
#' n/a, n/a, operational, hard".
#'
#' Codes `92` and `94` are printed in the guide as "Bridge :" with nothing after
#' the colon; the truncated part is not recoverable, so both are given as
#' "Bridge" and separated by [cs_domain_disambiguate()].
#'
#' @return A tibble of `code` and `label`.
#' @keywords internal
#' @noRd
cs_domain_rnf_2001_class <- function() {
  tibble::tribble(
    ~code,   ~label,
    "0",     "Unknown",
    "1",     "Unknown from Elections Canada",
    "92",    "Bridge",
    "94",    "Bridge",
    "201",   "Primary and secondary road functioning",
    "202",   "Primary and secondary road under construction",
    "301",   "Track, trail or footpath functioning",
    "994",   "Road: less than 2 lanes, all season, undivided, depression, operational, hard",
    "996",   "Road: less than 2 lanes, all season, undivided, n/a, under construction, hard",
    "997",   "Road: less than 2 lanes, all season, undivided, n/a, under construction, loose",
    "998",   "Road: less than 2 lanes, all season, undivided, other, operational, hard",
    "999",   "Road: less than 2 lanes, all season, undivided, other, operational, loose",
    "1000",  "Road: more than 2 lanes, all season, undivided, depression, operational, hard",
    "1001",  "Road: more than 2 lanes, all season, undivided, elevation, operational, hard",
    "1002",  "Road: more than 2 lanes, all season, undivided, n/a, under construction, hard",
    "1003",  "Road: more than 2 lanes, all season, undivided, other, operational, hard",
    "1004",  "Road: n/a, cart track, n/a other, operational, loose",
    "1005",  "Road: n/a, dry weather, undivided, other, operational, loose",
    "1006",  "Road: n/a, n/a, undivided, other, unclassified, n/a",
    "1009",  "Road: n/a, rapid transit, n/a, other, operational, hard",
    "1010",  "Road: n/a, rapid transit, n/a, n/a, under construction, hard",
    "1011",  "Road: n/a, street, n/a, n/a, operational, hard",
    "1012",  "Road: n/a, street, n/a, n/a, operational, loose",
    "1014",  "Road: 2 lanes, all season, undivided, elevated, operational, hard",
    "1015",  "Road: 2 lanes, all season, undivided, n/a, under construction, hard",
    "1016",  "Road: 2 lanes, all season, undivided, other, operational, hard",
    "1017",  "Road: 2 lines or more, all season, divided, depression, operational, hard",
    "1018",  "Road: 2 lines or more, all season, divided, elevated, operational, hard",
    "1019",  "Road: 2 lines or more, all season, divided, n/a, under construction, hard",
    "1020",  "Road: 2 lines or more, all season, divided, other, operational, hard",
    "1021",  "Road: 2 lines or more, all season, undivided, n/a, under construction, loose",
    "1022",  "Road: 2 lines or more, all season, undivided, other, operational, loose",
    "1027",  "Road: n/a, winter, n/a, other, operational, loose",
    "1306",  "Trail: other",
    "1307",  "Trail: portage",
    "1536",  "Neatline",
    "BO",    "Boundary arc",
    "SB",    "Sub-Block boundary arc",
    "U",     "Unknown"
  )
}

#' The modern Road Network File street class vocabulary
#'
#' Common to 2011 onward, and revised twice within it: 2016 adds `95` alongside
#' `90` ("90, 95 -- Unknown" in that year's guide) and 2021 retires `95` and adds
#' `87`. The wording follows the 2021 attribute domain page throughout, so that a
#' class means the same string in every vintage that carries it; only the set of
#' codes is per-vintage.
#'
#' @param vintage Reference year.
#' @return A tibble of `code` and `label`.
#' @keywords internal
#' @noRd
cs_domain_rnf_class <- function(vintage) {
  d <- tibble::tribble(
    ~code,  ~label,
    "10",   "Highway",
    "11",   "Expressway",
    "12",   "Primary highway",
    "13",   "Secondary highway",
    "20",   "Road",
    "21",   "Arterial",
    "22",   "Collector",
    "23",   "Local",
    "24",   "Alley / Lane / Utility",
    "25",   "Connector / Ramp",
    "26",   "Reserve / Trail",
    "27",   "Rapid transit",
    "28",   "Planned",
    "29",   "Strata",
    "80",   "Bridge / Tunnel",
    "87",   "Winter",
    "90",   "Unknown",
    "95",   "Unknown"
  )
  drop <- if (vintage >= 2021L) "95" else if (vintage >= 2016L) "87" else c("87", "95")
  d[!d$code %in% drop, ]
}

#' The modern Road Network File street rank vocabulary
#'
#' Unchanged from 2011 to 2021 but for the 2011 guide naming Transport Canada as
#' the authority for ranks 1 and 2; the 2016 and 2021 wording is used throughout.
#' Ranks are ordinal and the `ENUM` is declared in rank order, so `ORDER BY rank`
#' sorts Trans-Canada highways first.
#'
#' @param vintage Reference year.
#' @return A tibble of `code` and `label`.
#' @keywords internal
#' @noRd
cs_domain_rnf_rank <- function(vintage) {
  tibble::tribble(
    ~code, ~label,
    "1",   "Trans-Canada Highway",
    "2",   "National Highway System (not rank 1)",
    "3",   "Major Highway (not rank 1 or 2)",
    "4",   "Secondary Highway, Major Street (not rank 1, 2, or 3)",
    "5",   "All other streets (not rank 1, 2, 3, or 4)"
  )
}

#' Make every label in a domain unique
#'
#' A DuckDB `ENUM` cannot carry the same value twice, and three of these
#' vocabularies do give two codes the same description: 2016 defines `90` and
#' `95` both as "Unknown", 2001 has both `0` and `U` as "Unknown" and both `92`
#' and `94` as "Bridge", and the Street Network File's List A names both `WAQ`
#' and `SAQ` "Aqueduct". Rather than invent a distinction the source does not
#' make, every member of a colliding group keeps the published label with its own
#' code appended, so the code is still readable off the value.
#'
#' @param d A domain tibble of `code` and `label`.
#' @return The same tibble with duplicated labels disambiguated.
#' @keywords internal
#' @noRd
cs_domain_disambiguate <- function(d) {
  dup <- d$label %in% d$label[duplicated(d$label)]
  d$label[dup] <- paste0(d$label[dup], " (", d$code[dup], ")")
  d
}

#' The class domain that applies to a vintage
#'
#' @param vintage Reference year.
#' @return A tibble of `code` and `label`, or `NULL` for a vintage whose class
#'   codes have no published vocabulary.
#' @keywords internal
#' @noRd
cs_class_domain <- function(vintage) {
  src <- cs_source(vintage)
  if (!nrow(src)) return(NULL)
  vintage <- as.integer(vintage)
  d <- if (identical(src$product[1], "SNF")) {
    cs_domain_snf_class()
  } else if (vintage == 2001L) {
    cs_domain_rnf_2001_class()
  } else if (identical(src$product[1], "RNF") && vintage >= 2011L) {
    cs_domain_rnf_class(vintage)
  } else {
    # 2005-2010 document no class table and 2006 ships no class column; the
    # Area Master Files pre-date any published list.
    NULL
  }
  if (is.null(d)) NULL else cs_domain_disambiguate(d)
}

#' The rank domain that applies to a vintage
#'
#' @param vintage Reference year.
#' @return A tibble of `code` and `label`, or `NULL`.
#' @keywords internal
#' @noRd
cs_rank_domain <- function(vintage) {
  src <- cs_source(vintage)
  if (!nrow(src)) return(NULL)
  if (!identical(src$product[1], "RNF") || as.integer(vintage) < 2011L) {
    return(NULL)
  }
  cs_domain_disambiguate(cs_domain_rnf_rank(as.integer(vintage)))
}

#' Translate class codes into the labels a vintage is stored with
#'
#' The road-class filters in `R/sources.R` are written in the codes the source
#' files use, because that is how the reference guides name them. Import replaces
#' those codes with labels, so anything that compares against the stored column
#' has to go through here first. A code the vintage's domain does not define is
#' stored as itself and returned unchanged.
#'
#' @param vintage Reference year.
#' @param code Character vector of source codes.
#' @return A character vector of stored values, the same length as `code`.
#' @keywords internal
#' @noRd
cs_class_label <- function(vintage, code) {
  d <- cs_class_domain(vintage)
  if (is.null(d)) return(code)
  i <- match(code, d$code)
  ifelse(is.na(i), code, d$label[i])
}

#' Retype a coded column as a labelled `ENUM`
#'
#' Applied after every archive of a vintage has been inserted, because the `ENUM`
#' has to be declared over the values the whole table holds -- the Street Network
#' Files arrive as 51 separate shapefiles into one table.
#'
#' The declared type carries the vintage's entire published vocabulary, not only
#' the codes that happen to occur, so `enum_range(NULL::typeof(class))` is the
#' domain itself. Any code observed but *not* published is appended and stored as
#' the bare code: a vintage is never allowed to lose a value it actually carries
#' just because the guide does not explain it.
#'
#' @param con A writable DuckDB connection.
#' @param table Table name.
#' @param column `"class"` or `"rank"`.
#' @param domain The domain tibble, or `NULL` to do nothing.
#' @return `TRUE` if the column was retyped, `FALSE` otherwise.
#' @keywords internal
#' @noRd
cs_label_column <- function(con, table, column, domain) {
  if (is.null(domain) || !nrow(domain)) return(FALSE)
  qt <- DBI::dbQuoteIdentifier(con, table)
  qc <- DBI::dbQuoteIdentifier(con, column)

  observed <- DBI::dbGetQuery(con, paste0(
    "SELECT DISTINCT ", qc, "::VARCHAR AS code FROM ", qt,
    " WHERE ", qc, " IS NOT NULL"))$code
  if (!length(observed)) return(FALSE)

  extra <- sort(setdiff(observed, domain$code))
  values <- c(domain$label, extra)
  # A published label that collides with an unpublished code would make the
  # ENUM illegal; nothing in these vocabularies does, but the union is what the
  # type is built from, so make it safe rather than assume.
  values <- values[!duplicated(values)]

  lit <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
  cases <- paste0("WHEN ", lit(domain$code), " THEN ", lit(domain$label),
                  collapse = "\n         ")

  DBI::dbExecute(con, paste0(
    "ALTER TABLE ", qt, " ALTER COLUMN ", qc,
    " TYPE ENUM(", paste(lit(values), collapse = ", "), ")",
    " USING (CASE ", qc, "::VARCHAR\n         ", cases,
    "\n         ELSE ", qc, "::VARCHAR END);"))
  TRUE
}

#' Label a freshly imported vintage's coded columns
#'
#' @param con A writable DuckDB connection.
#' @param table Table name.
#' @param vintage Reference year.
#' @return A character vector naming the columns that were labelled, possibly
#'   empty, suitable for the metadata table.
#' @keywords internal
#' @noRd
cs_label_vintage <- function(con, table, vintage) {
  done <- c(
    class = cs_label_column(con, table, "class", cs_class_domain(vintage)),
    rank  = cs_label_column(con, table, "rank",  cs_rank_domain(vintage))
  )
  names(done)[done]
}

#' Statistics Canada attribute domains for the coded columns
#'
#' The `class` and `rank` columns of a road network are coded fields, and
#' Statistics Canada publishes the vocabulary once per census year. `canstreet`
#' applies these on import, so the columns come back as labelled factors rather
#' than as bare codes; this function exposes the same tables, which is what you
#' need to go back the other way -- from a label to the code the source file
#' carries, or to see the whole vocabulary including values a vintage happens not
#' to use.
#'
#' The vocabularies are genuinely per-vintage. 2016 defines class `95`
#' identically to `90`; 2021 retires `95` and adds `87` for winter roads; 2001
#' uses a numeric vocabulary with no code in common with 2011 onward; and the
#' 1991 and 1996 Street Network Files classify *features*, not roads, so most of
#' their vocabulary is watercourses, railways and boundaries. See
#' [get_road_network()] and its `roads_only` argument.
#'
#' Vintages with no published vocabulary return zero rows: 2005 to 2010, whose
#' reference guides document no class or rank table, and the 1976 and 1981 Area
#' Master Files, which pre-date any published list. Those vintages keep the codes
#' the source files carry.
#'
#' Sources, all primary: the Street Network File User Guide "List A" for 1991 and
#' 1996; the reference guide shipped inside each Road Network File archive for
#' 2001, 2011 and 2016; and the 2021 Census attribute domain values page for
#' 2021. Where a vintage gives two codes the same description -- 2016's `90` and
#' `95` are both "Unknown" -- each keeps the published wording with its own code
#' appended, because a DuckDB `ENUM` cannot hold the same value twice.
#'
#' @param vintage Reference year, or a vector of them. Defaults to every vintage
#'   in the manifest that has a published domain.
#' @param domain Which coded column to describe: `"class"`, `"rank"`, or both.
#' @return A tibble of `vintage`, `domain`, `code` and `label`.
#' @seealso [canstreet_schema()] for the columns themselves.
#' @export
#' @examples
#' canstreet_domains(2021)
#' canstreet_domains(2016, domain = "class")
canstreet_domains <- function(vintage = NULL, domain = c("class", "rank")) {
  domain <- match.arg(domain, several.ok = TRUE)
  if (is.null(vintage)) vintage <- cs_sources()$vintage
  vintage <- as.integer(vintage)

  out <- lapply(vintage, function(v) {
    parts <- lapply(domain, function(d) {
      tab <- switch(d, class = cs_class_domain(v), rank = cs_rank_domain(v))
      if (is.null(tab) || !nrow(tab)) return(NULL)
      tibble::tibble(vintage = v, domain = d, code = tab$code,
                     label = tab$label)
    })
    do.call(rbind, parts)
  })
  out <- do.call(rbind, out)
  if (is.null(out)) {
    return(tibble::tibble(vintage = integer(), domain = character(),
                          code = character(), label = character()))
  }
  out
}
