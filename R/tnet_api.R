#' Build a temporally unified road network
#'
#' Matches road segments across census vintages and writes a single table in
#' which every segment carries the list of years it is present in. Where the
#' vintages disagree about where a road is, the newest vintage's geometry is
#' the one kept, because positional accuracy improves across the series.
#'
#' # How segments are matched
#'
#' Arc-to-arc matching does not work on these files: the same road is split
#' into different numbers of arcs in different years, so requiring a whole arc
#' to correspond to a whole arc matches barely a third of them. Instead each
#' arc of the newest vintage is treated as a *spine*, the endpoints of nearby
#' arcs from other vintages are projected onto it, and it is cut at those
#' points, so a segment boundary appears wherever any vintage disagrees. Older
#' vintages contribute geometry only for the parts of their network no newer
#' vintage covers -- which is precisely the set of roads that have since been
#' retired.
#'
#' A match is either a close approach that also agrees on direction, or -- for
#' the long rural and highway arcs that older vintages digitize as a coarse
#' chord and newer ones as a detailed curve -- the same street name within
#' `name_far_m`. Statistics Canada states that in these files "topological
#' accuracy takes precedence over absolute positional accuracy", and without
#' the second rule the generalized arcs are reported as retired roads: in
#' Calgary that alone accounts for about 1,180 km of spurious road loss between
#' 2006 and 2021. [get_temporal_network_sources()] records which rule matched
#' each segment, so the rescue can be inspected or excluded.
#'
#' # What counts as a road
#'
#' The 1991 and 1996 Street Network Files are not road networks, and neither
#' are the 1976 and 1981 Area Master Files. They carry watercourses, railways,
#' hydro lines, census-boundary arcs and the outlines of parks, golf courses and
#' airports as arcs alongside the streets -- about a third of the 1996 file's
#' 160,000 km. 2001 has the same problem in a different form: it is the one year
#' whose line layer carries the boundary topology of the census geography,
#' 388,345 km of it, alongside the network.
#'
#' A road that had not been built yet is the other half of the question, and
#' every era spells it differently: 1996 classes Highway 403, Highway 407 and
#' Autoroute 50 "Highway proposed", 2001 writes "under construction" into eight
#' of its composite class descriptions, and 2016 and 2021 class about 200
#' subdivision streets apiece "Planned". Those arcs are drawn where the road was
#' going to go, so left in they date it to the vintage that anticipated it
#' rather than the one that first carried it.
#'
#' By default every vintage is therefore restricted to the class values
#' [canstreet_road_classes()] marks as road; `roads_only = FALSE` keeps
#' everything.
#'
#' # Regions change shape
#'
#' Restricting to a region is done by stamping one fixed boundary across every
#' year, never by filtering on `csduid_l` or `cmauid_l`. Statistics Canada
#' reuses those identifiers across boundary revisions, so the same code does
#' not mean the same ground in two different years -- and in any case the 1996
#' and 2006 files carry no region attributes at all. Each vintage's own
#' `csduid_l` is still recorded in the crosswalk, which is what makes the
#' boundary drift visible rather than hiding it.
#'
#' Source data are © Statistics Canada, distributed under the Statistics Canada
#' Open Licence (<https://www.statcan.gc.ca/en/reference/licence>).
#'
#' @param name Name for the build. Lower-case letters, digits and underscores;
#'   it becomes part of the table name. Building over an existing name replaces
#'   it.
#' @param vintages Reference years to build over -- any two or more of the
#'   vintages in [list_road_network_vintages()], in any spacing. The census
#'   years are a convention, not a requirement: `c(2005, 2006, 2007)` and
#'   `c(1996, 2025)` are equally valid builds, and a later build under a
#'   different `name` can use a different set. Any year not yet imported is
#'   downloaded and imported first. `NULL` uses every vintage the cache already
#'   holds, which is the cheap way to build over what you have.
#' @param within Optional spatial filter: an \pkg{sf} or `sfc` object, or a
#'   `bbox`. The same polygon is applied to every year. `NULL` builds the whole
#'   country, which is a far heavier job than a region and is not yet the
#'   supported scale: a national two-vintage build spilled over 32 GB of
#'   'DuckDB' temporary storage in the coverage pass during development and did
#'   not finish, where a CMA over five vintages takes about 20 seconds.
#' @param tolerance Distance tolerance in metres. `NULL` calibrates it per
#'   vintage from the data -- see [temporal_network_calibration()]. A single
#'   number applies to every vintage; a vector named by vintage sets each.
#' @param bearing_tol Bearing agreement required of a geometric match, in
#'   degrees. Measured locally, and folded by 180 degrees so a reversed
#'   digitization still agrees.
#' @param name_far_m Radius of the same-name rescue, in metres. `0` disables
#'   it, giving a strict-geometry build.
#' @param min_segment_m Shortest segment to emit; shorter pieces are absorbed
#'   into their neighbours.
#' @param roads_only Restrict each vintage to its road features, using that
#'   vintage's own vocabulary -- see [canstreet_road_classes()]. This matters
#'   most for 1976, 1981, 1991, 1996 and 2001: the Area Master Files and Street
#'   Network Files are full topographic bases, and a third of their length is
#'   watercourses, railways, hydro lines, census boundaries and the outlines of
#'   parks and airports, while 2001 carries the boundary arcs of the census
#'   geography, 22% of its length. Left in, every river, rail line and
#'   provincial boundary reads as a road that has since been removed. It also
#'   drops the arcs a vintage draws for a road that was not yet built -- 1996's
#'   "Highway proposed", 2001's "under construction", 2016's and 2021's
#'   "Planned" -- which would otherwise date a road to the year that
#'   anticipated it. `FALSE` keeps everything.
#'
#'   A character vector of build statuses is accepted in place of `TRUE`, as
#'   [get_road_network()] takes one, but widening it here is rarely what you
#'   want: keeping `"planned"` dates a road to the vintage that drew it rather
#'   than the one that first carried it, which is the confounder this whole
#'   function exists to avoid.
#' @param region_note Free text recorded with the build, to say what `within`
#'   was -- for instance which year's boundary file it came from.
#' @param refresh Rebuild even if a build of this name is already present.
#' @param quiet Suppress progress messages.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A lazy [dplyr::tbl()] over the new table, as
#'   [get_temporal_network()] would return.
#'
#' @seealso [get_temporal_network()], [get_temporal_network_sources()],
#'   [temporal_network_calibration()].
#'
#' @examples
#' \dontrun{
#' library(dplyr)
#'
#' # A region polygon -- any sf object will do. cancensus is one way to get one:
#' # cma <- cancensus::get_statcan_geographies("2021", level = "CMA") |>
#' #   dplyr::filter(CMANAME == "Calgary")
#'
#' calgary <- build_temporal_network(
#'   "calgary", c(1996, 2006, 2011, 2016, 2021),
#'   within = cma, region_note = "2021 CMA boundary, Calgary (825)")
#'
#' # How much road was present in exactly which set of years?
#' calgary |>
#'   group_by(year_key) |>
#'   summarize(km = sum(len_m) / 1000) |>
#'   arrange(desc(km)) |>
#'   collect()
#'
#' # Roads that were there in 1996 and are gone now.
#' calgary |>
#'   filter(last_year < 2021) |>
#'   collect_road_network()
#' }
#' @export
build_temporal_network <- function(name, vintages = NULL, within = NULL,
                                   tolerance = NULL, bearing_tol = 25,
                                   name_far_m = 200, min_segment_m = 10,
                                   roads_only = TRUE, region_note = NULL,
                                   refresh = FALSE, quiet = FALSE,
                                   cache_path = canstreet_cache_path()) {
  name <- cs_check_build_name(name)
  if (is.null(vintages)) {
    if (!file.exists(cs_db_path(cache_path))) {
      stop("`vintages` defaults to what the cache already holds, and this ",
           "cache is empty. Name the years to build over, or import some ",
           "first with `get_road_network()`.", call. = FALSE)
    }
    vintages <- cs_db_vintages(cs_connect(cache_path, read_only = TRUE))
  }
  years <- sort(unique(vapply(vintages, cs_check_vintage, integer(1))))

  if (!refresh && file.exists(cs_db_path(cache_path))) {
    con <- cs_connect(cache_path, read_only = TRUE)
    if (cs_db_has_build(con, name) &&
        identical(cs_builds_value(con, name, "vintages"),
                  paste(years, collapse = ","))) {
      return(get_temporal_network(name, cache_path = cache_path))
    }
  }

  # Importing needs the write lock, so the read-only handle has to go first.
  needed <- years
  if (file.exists(cs_db_path(cache_path))) {
    con <- cs_connect(cache_path, read_only = TRUE)
    needed <- years[!vapply(years, function(v) cs_db_has_vintage(con, v),
                            logical(1))]
  }
  con <- cs_connect(cache_path, read_only = FALSE)
  for (v in needed) {
    cs_import_vintage(con, v, quiet = quiet, cache_path = cache_path)
  }

  cs_build_tnet(con, name, years, within = within, tolerance = tolerance,
                bearing_tol = bearing_tol, name_far_m = name_far_m,
                min_segment_m = min_segment_m, roads_only = roads_only,
                region_note = region_note, quiet = quiet)

  get_temporal_network(name, cache_path = cache_path)
}

#' Access a temporal road network build
#'
#' Returns the harmonized table as a lazy \pkg{dbplyr} table. Nothing is read
#' into memory until you call [collect_road_network()], so an aggregation over
#' a national build runs inside the database.
#'
#' Columns: `segment_id`; `spine_vintage`, `spine_id`, `spine_piece`,
#' `spine_lo` and `spine_hi`, which say exactly which arc of which year's file
#' the geometry was cut from and where; `years`, a list column of the vintages
#' the segment is present in, with `year_key`, `n_years`, `first_year` and
#' `last_year` derived from it; the harmonized attribute columns, carried from
#' the spine arc; `len_m`; and `geom` in EPSG:3347.
#'
#' `year_key` is the same information as `years` written as `"1996|2006|2021"`.
#' Group by it to total road length by presence pattern; use `years` with
#' `list_contains()` to ask whether a particular year is in the set.
#'
#' @param name Build name passed to [build_temporal_network()].
#' @param within Optional spatial filter: an \pkg{sf} or `sfc` object, or a
#'   `bbox`. Uses the table's R-tree index.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A lazy [dplyr::tbl()] over the cached database.
#'
#' @examples
#' \dontrun{
#' get_temporal_network("calgary") |>
#'   dplyr::filter(n_years == 1, first_year == 2021) |>
#'   collect_road_network()
#' }
#' @export
get_temporal_network <- function(name, within = NULL,
                                 cache_path = canstreet_cache_path()) {
  name <- cs_check_build_name(name)
  con <- cs_connect(cache_path, read_only = TRUE)
  cs_require_build(con, name)

  sql <- paste0("SELECT * FROM ",
                DBI::dbQuoteIdentifier(con, cs_tnet_table_name(name)))
  if (!is.null(within)) sql <- paste0(sql, " WHERE ", cs_within_sql(within))
  dplyr::tbl(con, dbplyr::sql(sql))
}

#' The segment-to-source crosswalk for a build
#'
#' One row per segment per year it is present in, naming the arc of that year's
#' file it corresponds to. This is the matching itself, exposed: `match_kind`
#' says how the correspondence was established -- `"spine"` where the segment's
#' geometry came from that year, `"geometry"` or `"geometry+name"` where it was
#' found by proximity, and `"name_rescue"` where only the same-name rule at
#' longer range found it, which is the case for coarsely digitized long arcs.
#' `dist_m`, `name_match` and `bearing_diff` let a caller apply a stricter
#' standard than the build used.
#'
#' `src_name`, `csduid` and `csdname` are that year's own values, not the
#' newest year's. Comparing `csduid` across years shows where census
#' subdivision boundaries or codes changed under a road that did not move;
#' comparing `src_name` against the segment's `name` -- which is the spine
#' vintage's -- shows where a road was renamed. A rename is
#' `match_kind = "geometry"`: the arcs agree on position and bearing while the
#' folded names do not. Note that a blank `src_name` there is a road that
#' gained a name rather than one that changed it, and that the same-name rescue
#' cannot match across a rename by construction, so a road that was both
#' renamed and coarsely digitized reads as a retirement plus a new road.
#'
#' `source_file` is part of the arc's identity, not decoration: `source_id` is
#' unique only within one file for the AMF and SNF vintages, so joining a
#' crosswalk row back to its vintage table on `source_id` alone fans out.
#'
#' @param name Build name.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A lazy [dplyr::tbl()].
#'
#' @examples
#' \dontrun{
#' library(dplyr)
#' get_temporal_network_sources("calgary") |>
#'   count(vintage, match_kind) |>
#'   collect()
#'
#' # Candidate renames: the names disagree but the geometry does not.
#' get_temporal_network_sources("calgary") |>
#'   filter(match_kind == "geometry", src_name != "") |>
#'   inner_join(get_temporal_network("calgary"), by = "segment_id") |>
#'   count(vintage, src_name, name, sort = TRUE) |>
#'   collect()
#' }
#' @export
get_temporal_network_sources <- function(name,
                                         cache_path = canstreet_cache_path()) {
  name <- cs_check_build_name(name)
  con <- cs_connect(cache_path, read_only = TRUE)
  cs_require_build(con, name)
  dplyr::tbl(con, dbplyr::sql(paste0(
    "SELECT * FROM ",
    DBI::dbQuoteIdentifier(con, cs_tnet_src_table_name(name)))))
}

#' List the temporal network builds in a cache
#'
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A [tibble::tibble()] with one row per build: `name`, `vintages`,
#'   `n_segments`, `total_km`, `tolerance_m`, `name_far_m`, `regional`,
#'   `region_note` and `built_at`.
#'
#' @examples
#' \dontrun{
#' list_temporal_networks()
#' }
#' @export
list_temporal_networks <- function(cache_path = canstreet_cache_path()) {
  empty <- tibble::tibble(
    name = character(), vintages = character(), n_segments = integer(),
    total_km = numeric(), tolerance_m = character(), name_far_m = numeric(),
    regional = logical(), region_note = character(), built_at = character())
  if (!file.exists(cs_db_path(cache_path))) return(empty)

  con <- cs_connect(cache_path, read_only = TRUE)
  builds <- cs_db_builds(con)
  if (!length(builds)) return(empty)

  # `unname()` throughout: vapply() would otherwise name every column after the
  # builds, which travels into the tibble and out to the caller.
  val <- function(k, as = as.character) unname(vapply(
    builds, function(b) as(cs_builds_value(con, b, k)), as(character(1))))
  tibble::tibble(
    name = builds,
    vintages = val("vintages"),
    n_segments = suppressWarnings(val("n_segments", as.integer)),
    total_km = suppressWarnings(val("total_km", as.numeric)),
    tolerance_m = val("tolerance_m"),
    name_far_m = suppressWarnings(val("name_far_m", as.numeric)),
    regional = !is.na(val("region_wkt")),
    region_note = val("region_note"),
    built_at = val("built_at")
  )
}

#' How the matching tolerance was chosen
#'
#' Reports what the build measured before it matched anything, so the tolerance
#' can be judged rather than taken on trust. For each vintage against the
#' newest one in the build:
#'
#' \describe{
#'   \item{`recall_p50`, `recall_p90`}{How far an arc's midpoint sits from the
#'     nearest arc of the newest vintage carrying the same name. This is the
#'     positional disagreement between the two files.}
#'   \item{`disagree_10`, `disagree_25`, `disagree_40`}{The share of arcs whose
#'     *nearest* arc within that many metres carries a different name -- the
#'     rate at which the tolerance starts matching a road to its neighbour.}
#'   \item{`dx`, `dy`}{Mean displacement. Near zero means the disagreement is
#'     noise; a systematic offset would mean the two files are registered
#'     differently, which this package does not correct for and warns about.}
#' }
#'
#' @param name Build name.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A [tibble::tibble()], one row per calibrated vintage. Zero rows if
#'   the build used a supplied `tolerance` instead of calibrating.
#'
#' @examples
#' \dontrun{
#' temporal_network_calibration("calgary")
#' }
#' @export
temporal_network_calibration <- function(name,
                                         cache_path = canstreet_cache_path()) {
  name <- cs_check_build_name(name)
  con <- cs_connect(cache_path, read_only = TRUE)
  cs_require_build(con, name)

  raw <- cs_builds_value(con, name, "calibration")
  empty <- tibble::tibble(
    vintage = integer(), tolerance_m = numeric(), n_pairs = integer(),
    recall_p50 = numeric(), recall_p90 = numeric(), disagree_10 = numeric(),
    disagree_25 = numeric(), disagree_40 = numeric(), dx = numeric(),
    dy = numeric())
  if (is.na(raw)) return(empty)
  cal <- jsonlite::fromJSON(raw, simplifyVector = FALSE)
  if (!length(cal)) return(empty)

  pick <- function(x, path, default = NA_real_) {
    v <- x
    for (p in path) {
      if (is.null(v)) return(default)
      v <- v[[p]]
    }
    if (is.null(v) || !length(v)) default else as.numeric(v[[1]])
  }
  get <- function(...) unname(vapply(cal, pick, numeric(1), c(...)))
  tibble::tibble(
    vintage = as.integer(names(cal)),
    tolerance_m = get("tolerance_m"),
    n_pairs = as.integer(get("n_pairs")),
    recall_p50 = get("recall", "50%"),
    recall_p90 = get("recall", "90%"),
    disagree_10 = get("disagree", "d10"),
    disagree_25 = get("disagree", "d25"),
    disagree_40 = get("disagree", "d40"),
    dx = get("dx"),
    dy = get("dy")
  )
}

#' Remove a temporal network build
#'
#' Drops the build's tables and metadata. As elsewhere in this package,
#' dropping a table does not shrink the database file -- DuckDB reuses the
#' freed pages rather than returning them to the filesystem.
#'
#' @param name Build name, or a vector of names.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return The names removed, invisibly.
#'
#' @examples
#' \dontrun{
#' remove_temporal_network("calgary")
#' }
#' @export
remove_temporal_network <- function(name,
                                    cache_path = canstreet_cache_path()) {
  names <- vapply(name, cs_check_build_name, character(1))
  if (!file.exists(cs_db_path(cache_path))) return(invisible(names))

  con <- cs_connect(cache_path, read_only = FALSE)
  for (b in names) {
    for (t in c(cs_tnet_table_name(b), cs_tnet_src_table_name(b))) {
      DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ",
                                 DBI::dbQuoteIdentifier(con, t), ";"))
    }
    if (DBI::dbExistsTable(con, "canstreet_builds")) {
      DBI::dbExecute(con, "DELETE FROM canstreet_builds WHERE build = ?;",
                     params = list(b))
    }
  }
  invisible(names)
}

#' Fail helpfully when a build is missing or stale
#' @keywords internal
#' @noRd
cs_require_build <- function(con, name) {
  if (cs_db_has_build(con, name)) return(invisible(TRUE))
  have <- cs_db_builds(con)
  # Present but written by an older layout is a different fact from absent,
  # and the remedy is the same call, so say which one it is.
  if (name %in% have) {
    stop("The temporal network build \"", name, "\" was written by an older ",
         "layout of this package and cannot be read.\n",
         "Rebuild it with `build_temporal_network(\"", name, "\", c(...))`.",
         call. = FALSE)
  }
  stop("No temporal network build named \"", name, "\" in this cache.\n",
       if (length(have)) paste0("Available: ", paste(have, collapse = ", "),
                                ".\n") else "",
       "Build one with `build_temporal_network(\"", name, "\", c(...))`.",
       call. = FALSE)
}

#' Where census subdivision boundaries moved under a road that did not
#'
#' Statistics Canada reuses census subdivision codes across boundary revisions,
#' so the same `CSDUID` in two census years is not necessarily the same ground.
#' This is why [build_temporal_network()] restricts to a region by stamping one
#' fixed polygon across every year rather than by filtering on the attribute.
#'
#' Because the crosswalk records each vintage's own `csduid_l` against a segment
#' whose geometry is fixed, the drift becomes directly measurable: this function
#' reports, for each consecutive pair of vintages in the build, every change of
#' census subdivision along road that is present in both years. A road cannot
#' move between municipalities on its own, so every row is a boundary revision,
#' an annexation, or a recoding.
#'
#' Only vintages that carry the attribute can contribute. The 1996 Street
#' Network File and the 2006 Road Network File have no region columns at all,
#' which is the other half of the reason the spatial stamp is not optional.
#'
#' @param name Build name.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return A [tibble::tibble()] with `vintage_from`, `vintage_to`,
#'   `csduid_from`, `csdname_from`, `csduid_to`, `csdname_to`, `n_segments` and
#'   `km`, ordered by `km`. Zero rows if no vintage pair in the build carries
#'   the attribute, or if nothing changed.
#'
#' @examples
#' \dontrun{
#' temporal_network_region_drift("calgary")
#' }
#' @export
temporal_network_region_drift <- function(
    name, cache_path = canstreet_cache_path()) {
  name <- cs_check_build_name(name)
  con <- cs_connect(cache_path, read_only = TRUE)
  cs_require_build(con, name)

  tibble::as_tibble(DBI::dbGetQuery(con, paste0(
    "WITH s AS (\n",
    "  SELECT x.segment_id, x.vintage, x.csduid, x.csdname, t.len_m\n",
    "  FROM ", DBI::dbQuoteIdentifier(con, cs_tnet_src_table_name(name)),
    " x\n",
    "  JOIN ", DBI::dbQuoteIdentifier(con, cs_tnet_table_name(name)),
    " t USING (segment_id)\n",
    "  WHERE x.csduid IS NOT NULL AND x.csduid <> ''\n",
    "), p AS (\n",
    "  SELECT vintage AS vintage_from, csduid AS csduid_from,\n",
    "         csdname AS csdname_from, len_m,\n",
    "         lead(vintage) OVER w AS vintage_to,\n",
    "         lead(csduid)  OVER w AS csduid_to,\n",
    "         lead(csdname) OVER w AS csdname_to\n",
    "  FROM s WINDOW w AS (PARTITION BY segment_id ORDER BY vintage)\n",
    ")\n",
    "SELECT vintage_from, vintage_to, csduid_from, csdname_from,\n",
    "       csduid_to, csdname_to, count(*) AS n_segments,\n",
    "       sum(len_m) / 1000 AS km\n",
    "FROM p\n",
    "WHERE vintage_to IS NOT NULL AND csduid_from IS DISTINCT FROM csduid_to\n",
    "GROUP BY ALL ORDER BY km DESC;")))
}
