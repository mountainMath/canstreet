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
  if (vintage == 2001) {
    # 2001 is the one vintage where the `a` variant is *not* what to take. The
    # 2011 directory offers 2001 in two formats and `a` is a misnomer there:
    # the download page calls it ArcGIS but `grnf000r01a_e.zip` holds one
    # 1.5 GB ArcInfo interchange coverage, which no reader opens at a usable
    # speed. The `m` variant is MapInfo -- `grnf000r02ml_e.MIF`/`.MID`, the
    # road network, beside an `mp` pair that is the block polygons -- with the
    # same 2,053,112 arcs, a richer attribute table and a declared charset,
    # and DuckDB scans it whole in about half a minute -- where the coverage
    # reads at a few hundred arcs a second, which is over two hours.
    #
    # `lrnf000r01a_e`, `grnf000r01g_e` and `grnf000r01a_f` all return the
    # soft-404 signature. The same is true of the equivalent 1991 and 1996
    # paths -- those stay on Abacus.
    paste0(statcan_census_base, "2011/geo/rnf-frr/files-fichiers/",
           "grnf000r01m_e.zip")
  } else if (vintage == 2021) {
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

# 2005 is the first year of the 92-500-X series; 2001 predates it but is served
# from the same directory, so it rides along here rather than through Abacus.
# 2016 and 2021 are in the set but get their own paths, handled in
# `cs_statcan_url()`. There is no 2026 release: the catalogue page and the file
# URL both 404 as of 2026-08-28.
statcan_vintages <- c(2001, 2005:2025)

#' Source manifest for the historical road and street network files
#'
#' One row per vintage. This is the single place that knows where a vintage
#' comes from and what shape it arrives in; every other part of the package
#' reads it rather than hard-coding a URL.
#'
#' Columns:
#' \describe{
#'   \item{vintage}{Reference year of the network.}
#'   \item{product}{`"AMF"` (Area Master File), `"SNF"` (Street Network File)
#'     or `"RNF"` (Road Network File).}
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
#'     archive, which is a zip with a stub prepended and unzips normally;
#'     `"none"` is a bare file, which is how the Area Master Files arrive.}
#'   \item{schema_era}{Advisory grouping only. The attribute schema is *detected
#'     from the columns actually present* at import (see `cs_harmonize_sql()`),
#'     because it varies within these eras -- 1991 is upper-case with `ARC_ID`,
#'     1996 lower-case with `arc_id`, 2005 has `NGD_ID`, 2007 `RB_UID`, 2011+
#'     `NGD_UID`.}
#'   \item{crs}{EPSG code of the source coordinates. The 1991, 1996 and 2001
#'     files carry a degenerate `GEOGCS["Unknown"]` projection string that `sf`
#'     resolves to a missing CRS, so this value is assigned on import rather
#'     than read from the `.prj`. For the Area Master Files it records the
#'     datum only: their coordinates are projected, in a UTM zone that each map
#'     sheet states for itself, so the working CRS is chosen per sheet by
#'     `cs_amf_zone_crs()` and this column is not used to place them.}
#'   \item{coverage}{`"national"`; `"urban"` where the release covers only the
#'     larger urban areas; `"bc-urban"` for the two Area Master Files, which
#'     were deposited for British Columbia alone.}
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
    host = "statcan",
    resource = vapply(statcan_vintages, cs_statcan_url, character(1)),
    file_pattern = NA_character_,
    file_exclude = NA_character_,
    assembly = "single",
    archive = "zip",
    schema_era = ifelse(statcan_vintages >= 2011, "rnf_modern", "rnf_early"),
    crs = ifelse(statcan_vintages >= 2012, 3347L, 4269L),
    coverage = "national",
    notes = ifelse(statcan_vintages == 2001,
                   paste("The first national road network file, and the only",
                         "vintage that is not a shapefile: taken in the",
                         "MapInfo (.MIF/.MID) spelling, whose `ml` layer is",
                         "the road network and `mp` the block polygons.",
                         "Served from the 2011 directory. The ArcGIS variant",
                         "of the same release is an ArcInfo interchange",
                         "coverage that reads far more slowly and carries",
                         "fewer attributes."),
                   NA_character_),
    catalogue = ifelse(statcan_vintages == 2001, "92F0157GIE", "92-500-X")
  )

  abacus <- tibble::tribble(
    ~vintage, ~product, ~catalogue, ~resource, ~file_pattern, ~file_exclude,
    ~assembly, ~archive, ~schema_era, ~crs, ~coverage, ~notes,

    1976L, "AMF", NA_character_, "hdl:11272.1/AB2/MESORS",
    "[.]data$", NA_character_,
    "tiles", "none", "amf", 4267L, "bc-urban",
    paste("Two flat files, not an archive and not a GIS format:",
          "`vancouver.data` is the Vancouver census metropolitan area and",
          "`bc.data` the Victoria and Ioco-Anmore sheets. Coordinates are",
          "NAD27 UTM in a zone stated per map sheet. Read by `read_amf()`;",
          "no GDAL driver opens this format."),

    1981L, "AMF", NA_character_, "hdl:11272.1/AB2/K0EZ55",
    "[.]data$", NA_character_,
    "tiles", "none", "amf", 4267L, "bc-urban",
    paste("As 1976, but the EBCDIC original: the coordinates are packed",
          "decimal and reach the deposit as Latin-1 mojibake. `bc.data`",
          "covers Victoria, Kelowna, Kamloops and Prince George --",
          "Kelowna in UTM zone 11, the rest in zone 10."),

    1991L, "SNF", NA_character_, "hdl:11272.1/AB2/2FCGQJ",
    "^net_.*[.]zip$", NA_character_,
    "tiles", "zip", "snf", 4267L, "urban",
    paste("51 urban units, taken as the ArcInfo interchange coverages the",
          "deposit was made from rather than as the shapefiles derived from",
          "them. Four of those shapefiles -- Halifax, Chicoutimi-Jonquiere,",
          "Montreal and Toronto -- lost their arc identifiers in the",
          "conversion and had every field after a street name containing a",
          "comma shifted by one; Ottawa-Hull had its class and type merged.",
          "The coverages have none of that, and no Lambert twins to exclude."),

    1996L, "SNF", NA_character_, "hdl:11272.1/AB2/WFFBPW",
    "^gsnf.*r_e00[.]zip$", NA_character_,
    "tiles", "zip", "snf", 4267L, "urban",
    paste("50 urban units, taken as ArcInfo interchange coverages. The",
          "derived shapefiles in the same dataset carry the same features",
          "field for field, but the coverage is the deposited original. The",
          "parallel `s` archives are block and hydrography polygons, not",
          "streets.")
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
