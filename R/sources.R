# The source manifest.
#
# Every URL, handle, file pattern and CRS in this file was verified against a
# live request on 2026-08-28. The manifest is deliberately plain data: adding a
# vintage -- including the pre-1991 files, if they can be sourced -- is an edit
# to `cs_sources()` and nothing else.

statcan_census_base <- "https://www12.statcan.gc.ca/census-recensement/"

abacus_base <- "https://abacus.library.ubc.ca"

# Statistics Canada serves the whole 2006-2025 series from two directories, but
# neither the file prefix nor the path is stable across it:
#
#   * the prefix encodes the projection -- `g` geographic (lat/long), `l` the
#     StatCan Lambert conic (EPSG:3347). It flips at 2012.
#   * the letter before `_e` encodes the format -- `a` shapefile, `g` GML,
#     `f` file geodatabase, `p` GeoPackage. Only `a` is present in every
#     release, so we always take `a`. (Do not reach for the 2025 GeoPackage:
#     it carries CircularStrings that the DuckDB spatial extension rejects,
#     and the shapefile spells the same features as plain LINESTRINGs.)
#   * 2016 and 2021 sit in their own directories.
cs_statcan_url <- function(vintage) {
  yy <- sprintf("%02d", vintage %% 100)
  if (vintage == 2021) {
    paste0(statcan_census_base, "2021/geo/sip-pis/rnf-frr/files-fichiers/",
           "lrnf000r21a_e.zip")
  } else if (vintage == 2016) {
    paste0(statcan_census_base, "2011/geo/RNF-FRR/files-fichiers/2016/",
           "lrnf000r16a_e.zip")
  } else if (vintage <= 2011) {
    paste0(statcan_census_base, "2011/geo/RNF-FRR/files-fichiers/",
           "grnf000r", yy, "a_e.zip")
  } else {
    paste0(statcan_census_base, "2011/geo/RNF-FRR/files-fichiers/",
           "lrnf000r", yy, "a_e.zip")
  }
}

# 2005 is the first year of the 92-500-X series. 2016 and 2021 are in the set
# but get their own paths, handled in `cs_statcan_url()`. There is no 2026
# release: the catalogue page and the file URL both 404 as of 2026-08-28.
statcan_vintages <- 2005:2025

#' Source manifest for the historical road and street network files
#'
#' One row per vintage. This is the single place that knows where a vintage
#' comes from and what shape it arrives in; every other part of the package
#' reads it rather than hard-coding a URL.
#'
#' Columns:
#' \describe{
#'   \item{vintage}{Reference year of the network.}
#'   \item{product}{`"SNF"` (Street Network File) or `"RNF"` (Road Network File).}
#'   \item{catalogue}{Statistics Canada catalogue number, where the release has one.}
#'   \item{host}{`"statcan"` or `"abacus"`; selects the download backend.}
#'   \item{resource}{A direct URL for `statcan`, a Dataverse persistent
#'     identifier for `abacus`.}
#'   \item{file_pattern, file_exclude}{Case-insensitive regular expressions
#'     selecting the datafiles to fetch out of an Abacus dataset. `NA` for
#'     `statcan`, where `resource` already names one file.}
#'   \item{assembly}{`"single"` when the vintage is one national archive,
#'     `"tiles"` when it must be assembled from per-area units.}
#'   \item{archive}{Container format. `"exe"` is a Windows self-extracting
#'     archive, which is a zip with a stub prepended and unzips normally.}
#'   \item{schema_era}{Advisory grouping only. The attribute schema is *detected
#'     from the columns actually present* at import (see [cs_harmonize_sql()]),
#'     because it varies within these eras -- 1991 is upper-case with `ARC_ID`,
#'     1996 lower-case with `arc_id`, 2005 has `NGD_ID`, 2007 `RB_UID`, 2011+
#'     `NGD_UID`.}
#'   \item{crs}{EPSG code of the source coordinates. The 1991, 1996 and 2001
#'     files carry a degenerate `GEOGCS["Unknown"]` projection string that `sf`
#'     resolves to a missing CRS, so this value is assigned on import rather
#'     than read from the `.prj`.}
#'   \item{coverage}{`"national"`, or `"urban"` where the release covers only
#'     the larger urban areas.}
#'   \item{notes}{Human-readable caveats, surfaced by
#'     [list_road_network_vintages()].}
#' }
#'
#' @return A [tibble::tibble()] with one row per available vintage.
#' @keywords internal
#' @noRd
cs_sources <- function() {
  statcan <- tibble::tibble(
    vintage = as.integer(statcan_vintages),
    product = "RNF",
    catalogue = "92-500-X",
    host = "statcan",
    resource = vapply(statcan_vintages, cs_statcan_url, character(1)),
    file_pattern = NA_character_,
    file_exclude = NA_character_,
    assembly = "single",
    archive = "zip",
    schema_era = ifelse(statcan_vintages >= 2011, "rnf_modern", "rnf_early"),
    crs = ifelse(statcan_vintages >= 2012, 3347L, 4269L),
    coverage = "national",
    notes = NA_character_
  )

  abacus <- tibble::tribble(
    ~vintage, ~product, ~catalogue, ~resource, ~file_pattern, ~file_exclude,
    ~assembly, ~archive, ~schema_era, ~crs, ~coverage, ~notes,

    1991L, "SNF", NA_character_, "hdl:11272.1/AB2/2FCGQJ",
    "_shp[.]zip$", "^(LSNF|OT_HULL)",
    "tiles", "zip", "snf", 4267L, "urban",
    paste("51 urban units. The excluded LSNF205 and OT_HULL archives are the",
          "Lambert twins of GSNF205 (Halifax) and HULL_OTT (Ottawa-Hull) --",
          "identical features in a NAD27-based conic, and importing them",
          "would double-count those two areas."),

    1996L, "SNF", NA_character_, "hdl:11272.1/AB2/WFFBPW",
    "^gsnf.*r_shp[.]zip$", NA_character_,
    "tiles", "zip", "snf", 4267L, "urban",
    paste("43 urban units. The parallel `s` archives in the same dataset are",
          "block and hydrography polygons, not streets."),

    2001L, "RNF", "92F0157GIE", "hdl:11272.1/AB2/LPNCJ5",
    "^grnf000r02ml_e_shp[.]zip$", NA_character_,
    "single", "zip", "snf", 4269L, "national",
    paste("The `ml` variant is the road arcs; `mp` is block polygons. The `a`",
          "variant is an ArcInfo .e00 coverage of the same data and is skipped",
          "in favour of the shapefile.")
  )

  out <- dplyr::bind_rows(
    abacus[, c("vintage", "product", "catalogue", "resource", "file_pattern",
               "file_exclude", "assembly", "archive", "schema_era", "crs",
               "coverage", "notes")] |>
      dplyr::mutate(host = "abacus"),
    statcan
  )

  out <- out[, c("vintage", "product", "catalogue", "host", "resource",
                 "file_pattern", "file_exclude", "assembly", "archive",
                 "schema_era", "crs", "coverage", "notes")]
  out[order(out$vintage), ]
}

#' Look up one vintage in the source manifest
#'
#' @param vintage Integer reference year.
#' @return A one-row tibble.
#' @keywords internal
#' @noRd
cs_source <- function(vintage) {
  vintage <- cs_check_vintage(vintage)
  s <- cs_sources()
  s[s$vintage == vintage, , drop = FALSE]
}

#' Validate a single vintage against the manifest
#'
#' @param vintage Value supplied by the user.
#' @return The vintage as a length-one integer.
#' @keywords internal
#' @noRd
cs_check_vintage <- function(vintage) {
  if (length(vintage) != 1L || is.na(vintage)) {
    stop("`vintage` must be a single year, not ", length(vintage),
         " value(s).", call. = FALSE)
  }
  vintage <- suppressWarnings(as.integer(vintage))
  known <- cs_sources()$vintage
  if (is.na(vintage) || !vintage %in% known) {
    stop("No road network file is available for vintage ", vintage, ".\n",
         "Available vintages: ", cs_collapse_years(known), ".\n",
         "See `list_road_network_vintages()`.", call. = FALSE)
  }
  vintage
}

# Render a sorted integer vector as "1991, 1996, 2001, 2005, 2006-2025".
cs_collapse_years <- function(years) {
  years <- sort(unique(as.integer(years)))
  if (!length(years)) return("none")
  runs <- cumsum(c(1L, diff(years) != 1L))
  parts <- vapply(split(years, runs), function(r) {
    if (length(r) < 3L) paste(r, collapse = ", ") else paste0(min(r), "-", max(r))
  }, character(1))
  paste(parts, collapse = ", ")
}
