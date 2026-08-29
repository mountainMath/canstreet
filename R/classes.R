# Feature categories ----------------------------------------------------------
#
# `class` answers two different questions at once, and both have to be asked
# before a vintage can be treated as a road network.
#
# The first is whether the arc is a road at all. The 1976 and 1981 Area Master
# Files and the 1991 and 1996 Street Network Files are topographic bases, not
# road networks: alongside the streets they carry shorelines, watercourses,
# railways, hydro lines, and the outlines of parks, golf courses and
# municipalities. 2001 has the same problem in its own form -- its line layer
# carries the boundary topology of the census geography, 388,345 km of it. The
# Road Network Files from 2005 on carry none of that, so for them the question
# has one answer.
#
# The second is whether the road was there *in that year*. Every vocabulary
# that has ever had a word for it has one: the Street Network File classes an
# arc `HPR` "Highway proposed" (in 1996, Highway 403, Highway 407 and Autoroute
# 50 -- none of them open in 1996), 2001 spells "under construction" into eight
# of its composite descriptions, and 2011 onward class 28 "Planned", which in
# 2021 is 203 named-but-unbuilt subdivision streets. Those arcs are drawn where
# the road was going to go, so left in they date a road to the vintage that
# anticipated it rather than the one that first carried it -- which is exactly
# the measurement a temporal build is for.
#
# So a class gets two attributes here, and `cs_road_class_sql()` filters on
# both. `category` is the feature family, of which only `road` is a road;
# `status` is `operational`, `planned`, `under_construction`, or `unknown`
# where the source says a status field is unclassified.
#
# The assignments are per vintage and were made by reading the arcs, not by
# reading across from a similar label in another year -- because the same word
# does not mean the same thing twice in this series. 1996's `FTR` "Trail" is
# the Bruce Trail and numbered park paths, so it is not a road; 2001's `1306`
# "Trail: other" is the Klondike, Alaska and Dempster highways, so it is. 2021's
# class 26 "Reserve / Trail" is 92,000 km of forest service and resource road
# (2,470 arcs typed `FSR`, 5,103 typed `RD`), so it is. Class 27 "Rapid transit"
# is Ottawa's Transitway, a road that carries buses, so it is.

#' The feature category and build status of each class code
#'
#' One row per code in the vintage's vocabulary. Codes are the ones the source
#' files carry; import stores the labels those stand for, so anything comparing
#' against the stored column goes through `cs_class_label()` first.
#'
#' The Area Master Files are the one product with a categorization but no
#' published vocabulary -- see `cs_categories_amf()` for why List A cannot be
#' reused for them -- so their codes are given here and stay bare in the data.
#'
#' @param vintage Reference year.
#' @return A tibble of `code`, `category` and `status`, or `NULL` for a vintage
#'   that carries no class column.
#' @keywords internal
#' @noRd
cs_class_categories <- function(vintage) {
  src <- cs_source(vintage)
  if (!nrow(src)) return(NULL)
  vintage <- as.integer(vintage)
  if (identical(src$product[1], "AMF")) return(cs_categories_amf())
  if (identical(src$product[1], "SNF")) return(cs_categories_snf())
  if (vintage == 2001L) return(cs_categories_rnf_2001())
  if (vintage >= 2011L) return(cs_categories_rnf(vintage))
  # 2005-2010 ship no class column and document no vocabulary.
  NULL
}

# The Area Master File vocabulary, read off the four deposits: an ordinary
# street carries no class at all (146,693 of the 194,000 node records), and a
# class names a feature type of which only three are road. `HN` is the highway
# (Trans-Canada, Gaglardi Way and the interchanges), `Z` the arterial (Kingsway,
# Lougheed Highway -- 63% addressed, the only classed value that is), and `BN`
# the bridge or tunnel. Nothing in this vocabulary distinguishes a road that was
# not yet built.
#
# It is read from the data because no guide for it survives. The 1991 Street
# Network File guide has an Area Master File variant (`snfamf.pdf`) that
# decomposes the class into feature type, sub-type and street type, and it
# explains most of these two-character codes -- but it makes `IN` "Falls / Dam"
# where the data reads as island, and `Z` "hydroline, telephone, fence,
# pipeline" where the Area Master File's `Z` arcs are Kingsway and Lougheed
# Highway. 1976 and 1981 use an earlier revision of the vocabulary, so List A
# cannot be read across to them.
cs_categories_amf <- function() {
  tibble::tribble(
    ~code, ~category,
    "HN",  "road",         # highway
    "Z",   "road",         # arterial
    "BN",  "road",         # bridge or tunnel
    "SN",  "water",        # shoreline
    "WN",  "water",        # watercourse
    "IN",  "water",        # island outline
    "RN",  "rail",
    "MB",  "boundary",     # municipal
    "UB",  "boundary",     # urban-rural
    "OB",  "boundary",     # other
    "CB",  "boundary",     # other
    "GB",  "property",     # park, reserve or institution outline
    "PP",  "property"      # park or school property
  ) |>
    dplyr::mutate(status = "operational")
}

# List A of the Street Network File User Guide. The road families are the
# highways (`H*`), the bridges and tunnels (`B*`), the addressable multiple
# street `E`, and the roadway-associated `F`, `FRA` (ramp) and `FEX` (feature
# extension) -- but not `FTR` and `FWA`, which are the Bruce Trail, numbered
# park trails, bicycle paths and canal walkways.
#
# `HPR` and `HUC` are the two classes that say a highway was not open in the
# year that carries it. `HPR` is 85 arcs and 53 km in 1996 -- Highway 403,
# Highway 407 and Autoroute 50 -- and none at all in 1991; `HUC` occurs in
# neither.
#
# This is not the only place the Street Network File records an unbuilt road:
# the fixed-width `NAME` field packs a status suffix that survives as interior
# spaces, `CLAIRVIEW      PROP.` and `DESAUTELS     PROJ.`, on 2,182 arcs in
# 1991 and 932 in 1996. That is a name-parsing question rather than a class one
# and is deliberately left alone here.
cs_categories_snf <- function() {
  road <- c("E", "HSI", "HMU", "H", "BSI", "BMU", "BMN", "B", "FRA", "FEX", "F")
  fam <- c(R = "rail", W = "water", S = "water", I = "water", M = "boundary",
           C = "boundary", U = "boundary", G = "property", P = "property",
           O = "topography", Z = "utility", D = "other")
  d <- cs_domain_snf_class()
  # Every remaining code is named by its family's initial letter, which is what
  # List A is organized by; `FTR` and `FWA` are the two that fall outside it.
  cat <- unname(fam[substr(d$code, 1, 1)])
  cat[d$code %in% c("FTR", "FWA")] <- "path"
  cat[d$code %in% road] <- "road"
  cat[d$code %in% c("HPR", "HUC")] <- "road"
  status <- ifelse(d$code == "HPR", "planned",
                   ifelse(d$code == "HUC", "under_construction", "operational"))
  stopifnot(!anyNA(cat))
  tibble::tibble(code = d$code, category = cat, status = status)
}

# 2001. Everything whose description begins "Road:" is a road, as are the two
# bridges, the unknown codes -- `U` alone is 249,126 arcs, 83% of them named --
# and the three trail codes, whose arcs are the northern highway network: the
# longest named `1306` arcs are the Klondike, Alaska, Dempster and Canol, and
# the longest `301` arcs are Highways 58, 88 and 135 and the winter tractor
# trails. `1307` "Trail: portage" is 346 unnamed arcs in the same NWT and Yukon
# interior; nothing in the data says it is not road, so it is kept with the
# rest of them.
#
# `BO`, `SB` and `1536` are the census topology and the neatline: not one of
# the 172,152 arcs between them carries a name, a street type or an address
# range, in Calgary only 60 of 1,057 `BO` arcs come within 10 m of a road, and
# `1536`'s longest arcs run along 141 W and across 85-87 N. Dropping the three
# leaves 1,329,337 km against 2006's 1,326,099 km, 0.24% apart: the whole
# 388,345 km surplus was topology.
#
# Eight descriptions carry "under construction" in their status slot, 360 arcs
# and 456 km between them, which takes the total to 1,328,881 km; `1006` reads
# "unclassified" there, and is kept.
cs_categories_rnf_2001 <- function() {
  d <- cs_domain_rnf_2001_class()
  cat <- rep("road", nrow(d))
  cat[d$code %in% c("BO", "SB")] <- "boundary"
  cat[d$code == "1536"] <- "other"
  uc <- c("202", "996", "997", "1002", "1010", "1015", "1019", "1021")
  status <- ifelse(d$code %in% uc, "under_construction",
                   ifelse(d$code == "1006", "unknown", "operational"))
  tibble::tibble(code = d$code, category = cat, status = status)
}

# 2011 onward. The Road Network File is a road network, so every class in it is
# a road -- including `26` "Reserve / Trail", which is the forest service and
# resource road network rather than a footpath, `27` "Rapid transit", which is
# Ottawa's Transitway, `29` "Strata", `87` "Winter", and the unknowns. The one
# class that is a road only in prospect is `28` "Planned": 194 arcs in 2016 and
# 203 in 2021, drawn along subdivision streets that the year's own file says are
# not there yet.
cs_categories_rnf <- function(vintage) {
  d <- cs_domain_rnf_class(vintage)
  tibble::tibble(code = d$code, category = "road",
                 status = ifelse(d$code == "28", "planned", "operational"))
}

#' The categories and statuses a road filter keeps
#'
#' @return A character vector.
#' @keywords internal
#' @noRd
cs_road_categories <- function() "road"

cs_road_statuses <- function() c("operational", "unknown")

# Every build status the vocabularies use, widest last: the first two are the
# roads that were there in the reference year, the last two the ones that were
# not yet.
cs_class_statuses <- function() {
  c("operational", "unknown", "under_construction", "planned")
}

#' Resolve a `roads_only` argument to the build statuses it keeps
#'
#' `FALSE` is no filter at all and `TRUE` the roads that existed in the
#' reference year. A character vector names the statuses to keep, which is what
#' a caller geocoding addresses wants: the 194 arcs classed "Planned" in 2016
#' carry 177 addressed block faces, and every one of their street names is in
#' the 2021 file, so they were built -- the class dates the road early, it does
#' not invent it.
#'
#' @param roads_only The user's argument.
#' @param arg Its name, for the error message.
#' @return A character vector of statuses, or `NULL` for no filter.
#' @keywords internal
#' @noRd
cs_roads_only_statuses <- function(roads_only, arg = "roads_only") {
  if (is.null(roads_only) || isFALSE(roads_only)) return(NULL)
  if (isTRUE(roads_only)) return(cs_road_statuses())
  if (!is.character(roads_only) || !length(roads_only) || anyNA(roads_only)) {
    stop("`", arg, "` must be TRUE, FALSE, or a character vector of build ",
         "statuses.\nKnown statuses: ",
         paste(cs_class_statuses(), collapse = ", "), ".", call. = FALSE)
  }
  bad <- setdiff(roads_only, cs_class_statuses())
  if (length(bad)) {
    stop("Unknown build status in `", arg, "`: ",
         paste0("\"", bad, "\"", collapse = ", "), ".\n",
         "Known statuses: ", paste(cs_class_statuses(), collapse = ", "),
         ".\nSee `canstreet_road_classes()`.", call. = FALSE)
  }
  unique(roads_only)
}

#' Whether a vintage's filter names what to keep or what to drop
#'
#' The distinction is about the codes the vocabulary does *not* define, which
#' import stores bare. In a topographic base an undocumented code is not
#' assumed to be a road, so the filter names what to keep; in a road network it
#' is, so the filter names what to drop and everything else stays.
#'
#' @param vintage Reference year.
#' @return `"keep"` or `"drop"`.
#' @keywords internal
#' @noRd
cs_class_filter_sense <- function(vintage) {
  if (identical(cs_source(vintage)$product[1], "RNF")) "drop" else "keep"
}

#' A predicate restricting a vintage to its road features
#'
#' `NULL` when the vintage needs no filter -- 2005 to 2010, which carry no class
#' column and are roads already. An unclassed arc is kept by every vintage's
#' predicate: in the Area Master Files and the Street Network Files a blank
#' class *is* the ordinary street, and in a Road Network File it is an arc whose
#' class was not recorded.
#'
#' @param vintage Reference year.
#' @param column Name of the class column, so the predicate can be applied to an
#'   alias.
#' @param statuses Build statuses to keep. Defaults to the roads that were there
#'   in the reference year, dropping the planned and under-construction ones.
#' @return A SQL predicate string, or `NULL` if the vintage needs no filter.
#' @keywords internal
#' @noRd
cs_road_class_sql <- function(vintage, column = "class",
                              statuses = cs_road_statuses()) {
  cats <- cs_class_categories(vintage)
  if (is.null(cats) || !nrow(cats)) return(NULL)

  road <- cats$category %in% cs_road_categories() & cats$status %in% statuses
  codes <- if (identical(cs_class_filter_sense(vintage), "keep")) {
    cats$code[road]
  } else {
    cats$code[!road]
  }
  if (!length(codes)) return(NULL)

  # The vocabularies are written in the codes the reference guides use, but
  # import stores the labels those codes stand for -- see `cs_class_domain()` --
  # so everything is translated before it is compared against the column. For a
  # vintage with no published domain the translation is identity.
  op <- if (identical(cs_class_filter_sense(vintage), "keep")) "IN" else "NOT IN"
  paste0("(", column, " IS NULL OR ", column, " ", op, " (",
         paste0("'", cs_class_label(vintage, codes), "'", collapse = ", "),
         "))")
}

#' A road filter spanning several vintages
#'
#' Each vintage constrains only its own rows, which is what makes the predicate
#' usable over the `segments` view: a vintage that needs no filter contributes
#' nothing, rather than excluding the others.
#'
#' @param vintages Reference years.
#' @param qualify Prefix each predicate with its vintage. Needed whenever the
#'   rows being filtered come from more than one.
#' @param statuses Build statuses to keep, as `cs_road_class_sql()` takes them.
#' @return A SQL predicate string, or `NULL` if no vintage needs a filter.
#' @keywords internal
#' @noRd
cs_roads_only_sql <- function(vintages, qualify = length(vintages) > 1L,
                              statuses = cs_road_statuses()) {
  parts <- lapply(vintages, function(v) {
    p <- cs_road_class_sql(v, statuses = statuses)
    if (is.null(p)) return(NULL)
    if (qualify) paste0("(vintage <> ", v, " OR ", p, ")") else p
  })
  parts <- unlist(parts)
  if (!length(parts)) return(NULL)
  paste(parts, collapse = " AND ")
}

#' What counts as a road in each vintage
#'
#' The `class` column says what kind of feature an arc is, and the vocabulary is
#' different in every era of this series -- so "keep the roads" is a different
#' set of values in every vintage. This is that answer, one row per class value
#' per vintage: its feature `category`, its build `status`, and `road`, which is
#' `TRUE` for the values [get_road_network()] keeps when `roads_only = TRUE` and
#' the values [build_temporal_network()] is built from.
#'
#' Two questions are being answered at once. The first is whether the arc is a
#' road at all: the 1976 and 1981 Area Master Files and the 1991 and 1996 Street
#' Network Files are topographic bases carrying shorelines, watercourses,
#' railways, hydro lines and the outlines of parks and municipalities alongside
#' the streets, and 2001 carries the boundary arcs of the census geography --
#' 388,345 km of them. The Road Network Files from 2005 on carry none of this.
#'
#' The second is whether the road was there in the reference year. Arcs classed
#' "Highway proposed" in 1996 (Highway 403, Highway 407, Autoroute 50), "under
#' construction" in 2001, or "Planned" in 2016 and 2021 are drawn where a road
#' was going to go. They are roads, and `category` calls them roads, but their
#' `status` is not `operational` and the default filter drops them -- otherwise
#' a road is dated to the vintage that anticipated it rather than the one that
#' first carried it.
#'
#' The assignments were made by reading the arcs rather than by matching labels
#' across years, because the same word does not mean the same thing twice here:
#' 1996's "Trail" is the Bruce Trail and numbered park paths, 2001's "Trail:
#' other" is the Klondike and Alaska highways, and 2021's "Reserve / Trail" is
#' 92,000 km of forest service road.
#'
#' Vintages 2005 to 2010 return zero rows: they carry no class column, and
#' everything in them is road.
#'
#' @param vintage Reference year, or a vector of them. Defaults to every vintage
#'   in the manifest.
#' @return A [tibble::tibble()] of `vintage`, `code`, `label`, `category`,
#'   `status` and `road`. `label` is the value the class column is stored as,
#'   and is the code itself for the Area Master Files, whose vocabulary
#'   Statistics Canada never published.
#' @seealso [canstreet_domains()] for the published vocabularies,
#'   [get_road_network()] for the filter itself.
#'
#' @examples
#' # What 1996 throws away, and what it keeps.
#' subset(canstreet_road_classes(1996), !road)
#'
#' # The only class the modern files exclude.
#' subset(canstreet_road_classes(2021), !road)
#' @export
canstreet_road_classes <- function(vintage = NULL) {
  if (is.null(vintage)) vintage <- cs_sources()$vintage
  vintage <- vapply(vintage, cs_check_vintage, integer(1))

  out <- lapply(vintage, function(v) {
    cats <- cs_class_categories(v)
    if (is.null(cats) || !nrow(cats)) return(NULL)
    tibble::tibble(
      vintage = v,
      code = cats$code,
      label = cs_class_label(v, cats$code),
      category = cats$category,
      status = cats$status,
      road = cats$category %in% cs_road_categories() &
        cats$status %in% cs_road_statuses()
    )
  })
  out <- do.call(rbind, out)
  if (is.null(out)) {
    return(tibble::tibble(vintage = integer(), code = character(),
                          label = character(), category = character(),
                          status = character(), road = logical()))
  }
  out
}
