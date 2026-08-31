# The temporal network: matching road segments across vintages.
#
# The problem these files pose is not that roads move, it is that they are
# re-digitized. Statistics Canada is explicit that in the RNF "topological
# accuracy takes precedence over absolute positional accuracy", and it shows:
# between 2006 and 2021 the median same-name arc midpoint moves about 12 m with
# a standard deviation of 13 m in each axis and no systematic offset, while a
# long rural or highway arc can be a two-point chord in one vintage and a
# many-vertex curve hundreds of metres away in the next.
#
# So matching cannot be arc-to-arc, and it cannot be a single distance
# threshold. Instead:
#
#   * Arcs are conflated onto a *spine* by linear referencing. Nearby endpoints
#     from other vintages are projected onto a spine arc, the arc is cut at
#     those measures, and each resulting interval is tested on its own. This is
#     indifferent to how either vintage chose to split its arcs, and to the
#     direction each was digitized in.
#   * The spine is assembled newest vintage first, so the newest geometry a
#     segment ever had is the geometry that represents it. Older vintages
#     contribute only the parts of their network that no newer vintage covers,
#     which is exactly the set of retired roads.
#   * The match predicate is a tight distance test gated on a *local* bearing,
#     plus a narrow same-name rescue at longer range for the generalized arcs.
#
# Arc-to-arc matching was measured before any of this was written, and does
# not work: requiring both endpoints and the midpoint of a 2006 Calgary arc to
# lie within 20 m of one 2021 arc matches 35% of them.
#
# What there is to build the alternative out of is narrower than PostGIS. The
# DuckDB spatial extension (1.5.4) has no `ST_Hausdorff`, `ST_FrechetDistance`,
# `ST_MaxDistance`, `ST_Split`, `ST_Snap`, `ST_Segmentize` or `ST_Relate`, so
# every geometric comparison here is assembled from `ST_LineLocatePoint`,
# `ST_LineSubstring`, `ST_LineInterpolatePoint` and `ST_Azimuth` -- check
# before reaching for a PostGIS function from memory. And DuckDB plans a
# cross-vintage `ST_DWithin` as a spatial join over a sequential scan,
# ignoring the persistent RTREE, which is why the expensive passes here are
# blocked on a grid instead of left to the index.
#
# One predicate serves both the residual test that builds the spine and the
# coverage test that tags the result. That is what makes `last_year` equal
# `spine_vintage` for every emitted row: a piece enters the spine from vintage
# v only because no newer vintage covered it, and the coverage test asks the
# same question of the same source tables.

cs_tnet_table_name <- function(name) paste0("tnet_", name)
cs_tnet_src_table_name <- function(name) paste0("tnet_", name, "_src")

#' Validate a build name
#'
#' The name becomes part of a table identifier, so it is restricted to what can
#' appear in one unquoted rather than escaped into something unreadable.
#' @keywords internal
#' @noRd
cs_check_build_name <- function(name) {
  if (!is.character(name) || length(name) != 1L || is.na(name)) {
    stop("`name` must be a single string naming the build.", call. = FALSE)
  }
  if (!grepl("^[a-z][a-z0-9_]*$", name)) {
    stop("`name` must start with a lower-case letter and contain only ",
         "lower-case letters, digits and underscores; got \"", name, "\".",
         call. = FALSE)
  }
  name
}

# Numbers reach SQL as literals, so they must never arrive in scientific
# notation -- `1e+05` is not a valid DuckDB numeric literal in every position.
cs_num <- function(x) format(as.numeric(x), scientific = FALSE, trim = TRUE)

#' Resolve the region and its halo into WKT
#'
#' The halo matters more than it looks. Sources are matched against the region
#' *buffered outward*, while only the spine is restricted to the region proper.
#' Without it, a road running along the boundary has its newer counterpart
#' clipped away and is reported as retired -- a boundary artefact that reads
#' exactly like a finding.
#'
#' @param within An `sf`, `sfc` or `bbox` object, or `NULL` for all of Canada.
#' @param halo_m Outward buffer applied to the match extent, in metres.
#' @return `NULL`, or a list with `region` and `halo` WKT strings.
#' @keywords internal
#' @noRd
cs_region_wkt <- function(within, halo_m) {
  if (is.null(within)) return(NULL)
  geom <- if (inherits(within, "bbox")) {
    sf::st_as_sfc(within)
  } else if (inherits(within, "sf")) {
    sf::st_geometry(within)
  } else if (inherits(within, "sfc")) {
    within
  } else {
    stop("`within` must be an sf, sfc or bbox object, not a ",
         class(within)[1], ".", call. = FALSE)
  }
  if (is.na(sf::st_crs(geom))) {
    stop("`within` has no CRS; set one with sf::st_crs() so it can be ",
         "reprojected to the storage CRS.", call. = FALSE)
  }
  region <- sf::st_union(sf::st_transform(geom, cs_storage_crs()))
  list(region = sf::st_as_text(region),
       halo = sf::st_as_text(sf::st_buffer(region, halo_m)))
}

cs_wkt_literal <- function(wkt) {
  paste0("st_geomfromtext('", gsub("'", "''", wkt), "')")
}

# ---- staging ----------------------------------------------------------------

cs_tnet_stage_name <- function(vintage, kind) {
  paste0("cs_stage_", kind, "_", vintage)
}

#' The folded street name the two match rules compare
#'
#' Upper-cased and accent-stripped, so that "Rue Seraphin" and "RUE SERAPHIN" --
#' both of which occur across these vintages -- compare equal. Never NULL, so
#' `=` on it is always a decidable test.
#'
#' A purely numeric ordinal loses its suffix, because Statistics Canada changed
#' how it spells one in the middle of the series: every vintage through 1996
#' writes Vancouver's west-side grid `15`, and 2001 onward writes `15th` (4,511
#' arcs in 2001, 5,043 by 2021, against not one in any of the four older files).
#' Unnormalized, `15 <> '15TH'` disables the name rescue across that boundary
#' for every numbered street in the city -- and that is exactly where it is
#' needed, because the pre-2001 lineage draws 15th Avenue some 45 m north of
#' where the modern files draw it, beyond any calibrated tolerance. The result
#' was the avenue being emitted twice, once retiring in 1996 and once appearing
#' in 2001. The rewrite is deliberately narrow: only a name that is digits plus
#' an ordinal suffix and nothing else. Measured over the Vancouver and Calgary
#' regions it creates no new collision at all -- every pair of 2021 arcs within
#' `name_far_m` sharing a normalized numeric name already shared a bare one.
#'
#' @param col Column expression holding the raw name.
#' @return A SQL expression.
#' @keywords internal
#' @noRd
cs_name_fold_sql <- function(col = "name") {
  paste0("regexp_replace(coalesce(upper(strip_accents(", col, ")), ''), ",
         "'^([0-9]+)(ST|ND|RD|TH)$', '\\1')")
}

#' Stage one vintage for matching
#'
#' Produces two temp tables: the *match* table over the haloed extent, which is
#' what the predicate is evaluated against, and the *spine* table clipped to the
#' region proper, which is what can contribute geometry to the result. With no
#' region both are the whole vintage and the clip is skipped.
#'
#' Multi-part geometry is exploded here. `ST_LineLocatePoint` and
#' `ST_LineSubstring` are defined on `LINESTRING` only, and a few archives do
#' ship the occasional `MULTILINESTRING`.
#'
#' @param con A writable DuckDB connection.
#' @param vintage Reference year.
#' @param region `NULL`, or the list returned by `cs_region_wkt()`.
#' @param roads_only Drop the non-road features the Street Network Files carry.
#'   `TRUE`, `FALSE`, or the build statuses to keep; resolved by
#'   `cs_roads_only_statuses()` and applied by `cs_road_class_sql()`.
#' @return The two table names, invisibly.
#' @keywords internal
#' @noRd
cs_tnet_stage <- function(con, vintage, region = NULL, roads_only = TRUE,
                          name_far_m = 0) {
  # `class` and `rank` are labelled ENUMs in the vintages that have a published
  # domain (`cs_class_domain()`), and the ENUM differs from vintage to vintage,
  # so they are cast back to VARCHAR as they are staged: a build unions arcs
  # from several vintages into one table, and two unequal ENUM types would have
  # to be reconciled somewhere. Downstream reads from the staged tables, so this
  # is the only place that needs it.
  attrs <- cs_target_schema()$column
  cols <- paste(vapply(attrs, function(a) {
    q <- as.character(DBI::dbQuoteIdentifier(con, a))
    if (a %in% c("class", "rank")) paste0(q, "::VARCHAR AS ", q) else q
  }, character(1)), collapse = ", ")
  # `source_file` is not a target-schema column, but the crosswalk needs it:
  # `source_id` is unique only within one source file for the AMF and SNF
  # vintages -- 1991 numbers each of its 51 coverages from scratch -- so
  # `(source_file, source_id)` is what identifies an arc of a given year.
  cols <- paste0(DBI::dbQuoteIdentifier(con, "source_file"), ", ", cols)
  src <- DBI::dbQuoteIdentifier(con, cs_table_name(vintage))

  match_tbl <- cs_tnet_stage_name(vintage, "match")
  spine_tbl <- cs_tnet_stage_name(vintage, "spine")

  # Both rules compare `name_fold`; `cs_name_fold_sql()` is its one definition.
  select_common <- paste0(
    "SELECT ", cols, ",\n",
    "       ", cs_name_fold_sql(), " AS name_fold,\n",
    "       geom\n")

  where <- "len_m > 0 AND geom IS NOT NULL"
  statuses <- cs_roads_only_statuses(roads_only)
  if (!is.null(statuses)) {
    road <- cs_road_class_sql(vintage, statuses = statuses)
    if (!is.null(road)) where <- paste0(where, " AND ", road)
  }
  if (!is.null(region)) {
    where <- paste0(where, " AND st_intersects(geom, ",
                    cs_wkt_literal(region$halo), ")")
  }

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, match_tbl),
    " AS\n", cs_explode_lines_sql(paste0(select_common, "FROM ", src,
                                         "\nWHERE ", where)), ";"))

  body <- if (is.null(region)) {
    # The match table carries no `len_m`: it is only ever asked about
    # proximity. The spine table is measured, so it gets one here.
    paste0("SELECT * EXCLUDE (geom), st_length(geom) AS len_m, geom FROM ",
           DBI::dbQuoteIdentifier(con, match_tbl))
  } else {
    cs_clip_sql(match_tbl, region$region, con)
  }
  # `seg_id` is assigned here rather than carried from `source_id`: clipping
  # and exploding can both turn one source arc into several rows, and every
  # later phase keys on one row of this table.
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, spine_tbl),
    " AS SELECT row_number() OVER () AS seg_id, * FROM (\n", body, "\n);"))

  out <- c(match = match_tbl, spine = spine_tbl)
  if (name_far_m > 0) {
    rescue_tbl <- cs_tnet_stage_name(vintage, "rescue")
    cs_build_rescue_index(con, match_tbl, rescue_tbl, name_far_m)
    out <- c(out, rescue = rescue_tbl)
  }
  invisible(out)
}

#' Wrap a select so that any multi-part geometry becomes one row per part
#' @keywords internal
#' @noRd
cs_explode_lines_sql <- function(inner) {
  paste0(
    "WITH base AS (\n", inner, "\n)\n",
    "SELECT * EXCLUDE (geom), geom FROM base\n",
    "WHERE st_geometrytype(geom) = 'LINESTRING'\n",
    "UNION ALL BY NAME\n",
    "SELECT b.* EXCLUDE (geom), d.part.geom AS geom\n",
    "FROM base b, unnest(st_dump(b.geom)) AS d(part)\n",
    "WHERE st_geometrytype(b.geom) <> 'LINESTRING'\n",
    "  AND st_geometrytype(d.part.geom) = 'LINESTRING'")
}

#' Clip a staged table to the region
#'
#' Arcs wholly inside pass through untouched -- intersecting every arc with a
#' detailed CMA boundary is the expensive part, and most arcs never touch it.
#' Only the ones that cross are intersected and dumped, so that `sum(len_m)` is
#' the length *in* the region rather than the full length of every arc that
#' happens to poke into it.
#' @keywords internal
#' @noRd
cs_clip_sql <- function(tbl, region_wkt, con) {
  t <- DBI::dbQuoteIdentifier(con, tbl)
  region <- cs_wkt_literal(region_wkt)
  paste0(
    "SELECT * EXCLUDE (geom), geom, st_length(geom) AS len_m\n",
    "FROM ", t, " WHERE st_within(geom, ", region, ")\n",
    "UNION ALL BY NAME\n",
    "SELECT s.* EXCLUDE (geom), d.part.geom AS geom,\n",
    "       st_length(d.part.geom) AS len_m\n",
    "FROM ", t, " s, unnest(st_dump(st_intersection(s.geom, ", region,
    "))) AS d(part)\n",
    "WHERE NOT st_within(s.geom, ", region, ")\n",
    "  AND st_geometrytype(d.part.geom) = 'LINESTRING'\n",
    "  AND st_length(d.part.geom) > 0")
}

# ---- the match predicate ----------------------------------------------------

#' The two matching rules, as SQL
#'
#' Rule A is geometric: within `tol` metres, and running in roughly the same
#' direction *locally*. Rule B is the generalization rescue: the same street
#' name, within a much larger radius. Rule B is deliberately narrow on both
#' counts -- name equality alone would join every "Main Street" in the country,
#' and proximity alone at 200 m would join a road to its neighbourhood.
#'
#' Both rules are generated here and nowhere else, so the residual test that
#' builds the spine and the coverage test that tags it can never diverge.
#'
#' Grid cell size for blocking the name rescue, in metres
#'
#' The rescue joins on street name, and street names are not selective: 2021
#' holds 1.94 million named arcs over only 130,105 distinct folded names, and
#' `MAIN` alone occurs 12,884 times. Nationally, `name_fold = name_fold` alone
#' pairs 956 million arcs before the distance predicate ever runs, which is why
#' a national build does not finish without this. Blocking the join on a coarse
#' grid cell as well makes the key selective: `MAIN` within one 5 km cell is a
#' handful of arcs.
#'
#' 5 km is comfortably larger than any sane `name_far_m`, so the exploded index
#' stays close to one row per arc, and it is exact rather than approximate --
#' see `cs_rescue_index_sql()`.
#'
#' @return A number, in metres.
#' @keywords internal
#' @noRd
cs_cell_m <- function() 5000

#' The grid cell a point falls in
#'
#' @param point SQL expression for a point.
#' @param axis `"x"` or `"y"`.
#' @return A SQL expression.
#' @keywords internal
#' @noRd
cs_cell_sql <- function(point, axis) {
  paste0("cast(floor(st_", axis, "(", point, ") / ", cs_num(cs_cell_m()),
         ") AS BIGINT)")
}

#' The rescue index: one row per arc per grid cell it could be found from
#'
#' An arc is registered in every cell its bounding box, expanded outward by
#' `name_far_m`, touches. Any point within `name_far_m` of the arc therefore
#' lies inside that expanded box, so its own cell is one of the registered
#' ones: the blocking is exact, not a heuristic, and no match is lost. Because
#' the cell is much larger than the expansion, most arcs register in exactly
#' one cell.
#'
#' @param con A DuckDB connection.
#' @param match_tbl Staged match table to index.
#' @param out Table to create.
#' @param name_far_m Rescue radius in metres.
#' @return `out`, invisibly.
#' @keywords internal
#' @noRd
cs_build_rescue_index <- function(con, match_tbl, out, name_far_m) {
  cell <- cs_num(cs_cell_m())
  far <- cs_num(name_far_m)
  edge <- function(fn, sign) {
    paste0("cast(floor((st_", fn, "(o.geom) ", sign, " ", far, ") / ", cell,
           ") AS BIGINT)")
  }
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, out), " AS\n",
    "SELECT o.source_file, o.source_id, o.name, o.name_fold,\n",
    "       o.csduid_l, o.csdname_l, o.geom,\n",
    "       cx, cy\n",
    "FROM ", DBI::dbQuoteIdentifier(con, match_tbl), " o,\n",
    "     unnest(range(", edge("xmin", "-"), ", ", edge("xmax", "+"),
    " + 1)) t(cx),\n",
    "     unnest(range(", edge("ymin", "-"), ", ", edge("ymax", "+"),
    " + 1)) u(cy)\n",
    "WHERE o.name_fold <> '';"))
  invisible(out)
}

#' @param point SQL expression for the point being tested.
#' @param az SQL expression for the spine-side local bearing at that point.
#' @param name SQL expression for the spine-side folded name.
#' @param src Table of candidate source arcs.
#' @param tol Distance tolerance in metres.
#' @param bearing_tol Bearing tolerance in degrees.
#' @param name_far_m Radius for the same-name rescue; `0` disables it.
#' @param short SQL boolean; `TRUE` where the bearing test should be skipped.
#' @param rescue_src Grid-blocked rescue index over `src`, from
#'   `cs_build_rescue_index()`. `NULL` disables the rescue.
#' @return A named list of SQL predicate strings, and their disjunction.
#' @keywords internal
#' @noRd
cs_match_rules_sql <- function(point, az, name, src, tol, bearing_tol,
                               name_far_m, short = "FALSE",
                               rescue_src = NULL) {
  geom <- paste0(
    "EXISTS (SELECT 1 FROM ", src, " o\n",
    "        WHERE st_dwithin(o.geom, ", point, ", ", cs_num(tol), ")\n",
    "          AND (", short, " OR cs_bearing_agree(cs_local_az(o.geom, ",
    point, "), ", az, ", ", cs_num(bearing_tol), ")))")

  rescue <- if (name_far_m > 0 && !is.null(rescue_src)) {
    paste0(
      "(", name, " <> '' AND EXISTS (SELECT 1 FROM ", rescue_src, " o\n",
      "        WHERE o.name_fold = ", name, "\n",
      "          AND o.cx = ", cs_cell_sql(point, "x"), "\n",
      "          AND o.cy = ", cs_cell_sql(point, "y"), "\n",
      "          AND st_dwithin(o.geom, ", point, ", ", cs_num(name_far_m),
      ")))")
  } else {
    NULL
  }

  list(geom = geom, rescue = rescue,
       any = if (is.null(rescue)) paste0("(", geom, ")")
             else paste0("(", geom, "\n     OR ", rescue, ")"))
}

# ---- cutting ----------------------------------------------------------------

#' Breakpoints: where other vintages' arcs end on a target arc
#'
#' Measures are snapped to a ~2 m grid so that the many endpoints a busy
#' intersection contributes collapse to one cut rather than to a fan of
#' zero-length slivers. Endpoints within 2% of either end are dropped: cutting
#' there produces a stub shorter than the tolerance that is testing it.
#'
#' @param con A writable DuckDB connection.
#' @param out Temp table to create.
#' @param target Table of arcs to cut, with `seg_id`, `geom`, `len_m`.
#' @param srcs Tables whose endpoints provide the cuts.
#' @param tol Distance within which an endpoint is considered to be on the arc.
#' @param snap_m Measure snapping grid, in metres.
#' @return `out`, invisibly.
#' @keywords internal
#' @noRd
cs_breakpoints <- function(con, out, target, srcs, tol, snap_m = 2) {
  pts <- paste(vapply(srcs, function(s) paste0(
    "SELECT st_startpoint(geom) AS pt FROM ", DBI::dbQuoteIdentifier(con, s),
    "\n    UNION ALL SELECT st_endpoint(geom) FROM ",
    DBI::dbQuoteIdentifier(con, s)), character(1)),
    collapse = "\n    UNION ALL ")

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, out), " AS\n",
    "SELECT DISTINCT seg_id, m FROM (\n",
    "  SELECT t.seg_id AS seg_id,\n",
    "         round(st_linelocatepoint(t.geom, p.pt) * t.len_m / ",
    cs_num(snap_m), ") * ", cs_num(snap_m), " / t.len_m AS m\n",
    "  FROM ", DBI::dbQuoteIdentifier(con, target), " t\n",
    "  JOIN (", pts, ") p\n",
    "    ON st_dwithin(t.geom, p.pt, ", cs_num(tol), ")\n",
    ") WHERE m > 0.02 AND m < 0.98;"))
  invisible(out)
}

#' Intervals between breakpoints, subdivided so no interval outruns the test
#'
#' Coverage is decided at an interval's midpoint, so an interval much longer
#' than the tolerance could have a covered midpoint and uncovered ends. Long
#' intervals are therefore split into equal pieces of at most `max_len_m`.
#'
#' `generate_series` cannot be used in a scalar position here -- it binds as an
#' operator on the list it returns -- so the fan-out is `unnest(range(...))`.
#'
#' @param con A writable DuckDB connection.
#' @param out Temp table to create.
#' @param target Table of arcs, with `seg_id`, `len_m`.
#' @param bp Breakpoint table from `cs_breakpoints()`.
#' @param max_len_m Longest interval to leave uncut, in metres.
#' @param min_len_m Intervals shorter than this are dropped as slivers.
#' @return `out`, invisibly.
#' @keywords internal
#' @noRd
cs_intervals <- function(con, out, target, bp, max_len_m, min_len_m = 0.5) {
  t <- DBI::dbQuoteIdentifier(con, target)
  b <- DBI::dbQuoteIdentifier(con, bp)
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, out), " AS\n",
    "WITH pts AS (\n",
    "  SELECT seg_id, 0.0 AS m FROM ", t, "\n",
    "  UNION ALL SELECT seg_id, 1.0 FROM ", t, "\n",
    "  UNION ALL SELECT seg_id, m FROM ", b, "\n",
    "), o AS (SELECT DISTINCT seg_id, m FROM pts),\n",
    "raw AS (\n",
    "  SELECT seg_id, m AS lo,\n",
    "         lead(m) OVER (PARTITION BY seg_id ORDER BY m) AS hi\n",
    "  FROM o\n",
    "), sized AS (\n",
    "  SELECT r.seg_id, r.lo, r.hi, t.len_m,\n",
    "         cast(greatest(1, ceil((r.hi - r.lo) * t.len_m / ",
    cs_num(max_len_m), ")) AS INTEGER) AS k\n",
    "  FROM raw r JOIN ", t, " t USING (seg_id)\n",
    "  WHERE r.hi IS NOT NULL AND (r.hi - r.lo) * t.len_m > ",
    cs_num(min_len_m), "\n",
    ")\n",
    "SELECT s.seg_id,\n",
    "       s.lo + (s.hi - s.lo) * w.g / s.k AS lo,\n",
    "       s.lo + (s.hi - s.lo) * (w.g + 1) / s.k AS hi,\n",
    "       s.len_m\n",
    "FROM sized s, unnest(range(0, s.k)) AS w(g);"))
  invisible(out)
}

#' Interval midpoints, with everything the predicate needs
#'
#' Materialized rather than expressed inline: the predicate is a correlated
#' subquery, and repeating `ST_LineInterpolatePoint` inside it once per rule
#' would recompute the point for every candidate arc.
#' @keywords internal
#' @noRd
cs_interval_points <- function(con, out, iv, target) {
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", DBI::dbQuoteIdentifier(con, out), " AS\n",
    "SELECT seg_id, lo, hi, len_m, piece_m, name_fold, mid,\n",
    "       cs_local_az(geom, mid) AS az\n",
    "FROM (\n",
    "  SELECT i.seg_id, i.lo, i.hi, i.len_m,\n",
    "         (i.hi - i.lo) * i.len_m AS piece_m,\n",
    "         t.name_fold, t.geom,\n",
    "         st_lineinterpolatepoint(t.geom, (i.lo + i.hi) / 2) AS mid\n",
    "  FROM ", DBI::dbQuoteIdentifier(con, iv), " i\n",
    "  JOIN ", DBI::dbQuoteIdentifier(con, target), " t USING (seg_id)\n",
    ");"))
  invisible(out)
}

#' Collapse adjacent intervals that agree on `key`
#'
#' The gap-and-island trick: two row numbers, one over the whole arc and one
#' within the key, differ by a constant exactly along a run of equal keys.
#' @keywords internal
#' @noRd
cs_merge_runs_sql <- function(inner, key) {
  paste0(
    "WITH g AS (\n", inner, "\n), h AS (\n",
    "  SELECT *, row_number() OVER (PARTITION BY seg_id ORDER BY lo)\n",
    "          - row_number() OVER (PARTITION BY seg_id, ", key,
    " ORDER BY lo) AS grp\n",
    "  FROM g\n)\n",
    "SELECT seg_id, ", key, ", min(lo) AS lo, max(hi) AS hi,\n",
    "       any_value(len_m) AS len_m\n",
    "FROM h GROUP BY seg_id, ", key, ", grp")
}

# ---- calibration ------------------------------------------------------------

#' Calibrate a distance tolerance against the data
#'
#' Two curves, from one join. The *recall* curve is how far an old arc's
#' midpoint sits from the nearest new arc carrying the same name -- how loose
#' the tolerance has to be to find the road again. The *precision* curve,
#' `name_disagree`, is the share of old midpoints whose nearest new arc within
#' `d` carries a different name -- how loose the tolerance can get before it
#' starts reaching across to the next street.
#'
#' The tolerance is read off the precision curve, not the coverage curve.
#' Measured on Calgary, coverage rises smoothly from 16.5% at 5 m to 73.1% at
#' 40 m with no knee anywhere, so it cannot choose a threshold; disagreement
#' stays flat while the tolerance is only absorbing positional noise and then
#' climbs, which can.
#'
#' A mean displacement over `shift_warn_m` would mean the two vintages are
#' registered differently, which this design does not correct for, so it warns
#' rather than quietly widening the tolerance.
#'
#' @param con A writable DuckDB connection.
#' @param old,new Staged match tables for the two vintages.
#' @param grid Candidate tolerances, in metres.
#' @param slack Extra disagreement tolerated above the tightest grid point.
#' @param bounds Hard clamp on the result, in metres.
#' @param shift_warn_m Mean displacement above which to warn. Below this the
#'   tolerance absorbs the offset; above it, it is a systematic registration
#'   difference this design does not correct.
#' @return A one-row list: `tolerance_m`, the two curves, `n_pairs`, `dx`, `dy`.
#' @keywords internal
#' @noRd
cs_calibrate_tolerance <- function(con, old, new, grid = seq(5, 40, by = 5),
                                   slack = 0.05, bounds = c(10, 40),
                                   shift_warn_m = 10) {
  o <- DBI::dbQuoteIdentifier(con, old)
  n <- DBI::dbQuoteIdentifier(con, new)
  far <- max(grid) * 4

  pairs <- tibble::as_tibble(DBI::dbGetQuery(con, paste0(
    "WITH shared AS (\n",
    "  SELECT DISTINCT name_fold FROM ", o, " WHERE name_fold <> ''\n",
    "  INTERSECT SELECT DISTINCT name_fold FROM ", n, "\n",
    "), p AS (\n",
    "  SELECT a.name_fold, st_lineinterpolatepoint(a.geom, 0.5) AS mid,\n",
    "         row_number() OVER () AS pid\n",
    "  FROM ", o, " a JOIN shared USING (name_fold)\n",
    ")\n",
    "SELECT p.pid, p.name_fold,\n",
    "       min(st_distance(b.geom, p.mid)) AS d_any,\n",
    "       arg_min(b.name_fold, st_distance(b.geom, p.mid)) AS near_name,\n",
    "       min(CASE WHEN b.name_fold = p.name_fold\n",
    "                THEN st_distance(b.geom, p.mid) END) AS d_same,\n",
    "       arg_min(st_x(st_closestpoint(b.geom, p.mid)) - st_x(p.mid),\n",
    "               CASE WHEN b.name_fold = p.name_fold\n",
    "                    THEN st_distance(b.geom, p.mid) END) AS dx,\n",
    "       arg_min(st_y(st_closestpoint(b.geom, p.mid)) - st_y(p.mid),\n",
    "               CASE WHEN b.name_fold = p.name_fold\n",
    "                    THEN st_distance(b.geom, p.mid) END) AS dy\n",
    "FROM p JOIN ", n, " b ON st_dwithin(b.geom, p.mid, ", cs_num(far), ")\n",
    "GROUP BY p.pid, p.name_fold;")))

  if (nrow(pairs) < 30L) {
    return(list(tolerance_m = mean(bounds), n_pairs = nrow(pairs),
                recall = NULL, disagree = NULL, dx = NA_real_, dy = NA_real_,
                calibrated = FALSE))
  }

  disagree <- vapply(grid, function(d) {
    in_range <- !is.na(pairs$d_any) & pairs$d_any <= d
    if (!any(in_range)) return(NA_real_)
    mean(pairs$near_name[in_range] != pairs$name_fold[in_range])
  }, numeric(1))

  # Largest tolerance whose disagreement has not yet risen meaningfully above
  # the tightest one measured.
  base <- disagree[which(!is.na(disagree))[1]]
  ok <- !is.na(disagree) & disagree <= base + slack
  d_precision <- if (any(ok)) max(grid[ok]) else min(grid)

  d_same <- pairs$d_same[!is.na(pairs$d_same)]
  recall <- if (length(d_same)) {
    stats::quantile(d_same, c(0.5, 0.75, 0.9, 0.95), names = TRUE)
  } else {
    NULL
  }
  d_recall <- if (length(d_same)) unname(stats::quantile(d_same, 0.9)) else Inf

  tol <- min(d_precision, ceiling(d_recall))
  tol <- min(max(tol, bounds[1]), bounds[2])

  dx <- mean(pairs$dx, na.rm = TRUE)
  dy <- mean(pairs$dy, na.rm = TRUE)
  if (isTRUE(sqrt(dx^2 + dy^2) > shift_warn_m)) {
    warning("Same-named arcs are systematically displaced by ",
            round(sqrt(dx^2 + dy^2), 1), " m (dx ", round(dx, 1), ", dy ",
            round(dy, 1), "), which is a large fraction of the matching ",
            "tolerance. canstreet absorbs displacement into that tolerance ",
            "rather than correcting the registration, so treat differences at ",
            "this scale as unresolved. `temporal_network_calibration()` ",
            "reports the full figures.", call. = FALSE)
  }

  list(tolerance_m = tol, n_pairs = nrow(pairs),
       recall = recall,
       disagree = stats::setNames(disagree, paste0("d", grid)),
       d_precision = d_precision, dx = dx, dy = dy, calibrated = TRUE)
}

#' "Is this point on a road that any of these vintages had?"
#'
#' The disjunction is taken over the vintages *individually*, each with its own
#' tolerance, rather than over a merged pool of their arcs. That is what keeps
#' the residual test used to build the spine identical to the coverage test
#' used to tag it: `covered by some newer vintage` is by construction the same
#' expression as `OR` of the per-vintage coverage tests, so a piece can never
#' enter the spine as retired and then be found present in a newer year.
#'
#' @param specs A list of `list(src=, rescue=, tol=, name_far=)`, one per
#'   vintage.
#' @inheritParams cs_match_rules_sql
#' @return A SQL boolean expression.
#' @keywords internal
#' @noRd
cs_covered_by_sql <- function(point, az, name, specs, bearing_tol,
                              short = "FALSE") {
  if (!length(specs)) return("FALSE")
  parts <- vapply(specs, function(s) {
    cs_match_rules_sql(point, az, name, s$src, s$tol, bearing_tol,
                       s$name_far, short, s$rescue)$any
  }, character(1))
  paste0("(", paste(parts, collapse = "\n    OR "), ")")
}

#' Build the spine, newest vintage first
#'
#' Every arc of the newest vintage enters whole. Each earlier vintage then
#' contributes only the parts of its arcs that no newer vintage covers -- which
#' is what "a road that has since been retired" means -- so the geometry
#' representing a segment is always the newest geometry it ever had. That is
#' the whole of the "prefer newer geocoding" rule: it is structural, not a
#' tie-break applied afterwards.
#'
#' @param con A writable DuckDB connection.
#' @param out Temp table to create.
#' @param staged Named list of staged table pairs, in descending vintage order.
#' @param specs Per-vintage match specs, in the same order.
#' @param bearing_tol Bearing tolerance in degrees.
#' @param min_segment_m Shortest residual worth keeping.
#' @param quiet Suppress progress messages.
#' @return `out`, invisibly.
#' @keywords internal
#' @noRd
cs_build_spine <- function(con, out, staged, specs, bearing_tol,
                           min_segment_m, quiet = FALSE) {
  attrs <- cs_target_schema()$column
  cols <- paste(DBI::dbQuoteIdentifier(con, attrs), collapse = ", ")
  vintages <- as.integer(names(staged))
  o <- DBI::dbQuoteIdentifier(con, out)

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE ", o, " AS\n",
    "SELECT ", vintages[1], " AS spine_vintage, source_id AS spine_id,\n",
    "       0 AS spine_piece, ", cols, ", name_fold, geom\n",
    "FROM ", DBI::dbQuoteIdentifier(con, staged[[1]]$spine), ";"))

  max_tol <- max(vapply(specs, function(s) s$tol, numeric(1)))

  for (k in seq_along(staged)[-1]) {
    v <- vintages[k]
    target <- staged[[k]]$spine
    cs_message(quiet, "  residual for ", v, " ...")

    cs_breakpoints(con, "cs_bp", target,
                   vapply(staged[seq_len(k - 1)], function(s) s$match,
                          character(1)),
                   tol = max_tol)
    cs_intervals(con, "cs_iv", target, "cs_bp", max_len_m = 3 * max_tol)
    cs_interval_points(con, "cs_pt", "cs_iv", target)

    covered <- cs_covered_by_sql("x.mid", "x.az", "x.name_fold",
                                 specs[seq_len(k - 1)], bearing_tol,
                                 short = "x.piece_m < 15")

    inner <- paste0(
      "  SELECT x.seg_id, x.lo, x.hi, x.len_m,\n",
      "         ", covered, " AS covered\n",
      "  FROM cs_pt x")

    DBI::dbExecute(con, paste0(
      "INSERT INTO ", o, "\n",
      "WITH runs AS (\n", cs_merge_runs_sql(inner, "covered"), "\n)\n",
      "SELECT ", v, " AS spine_vintage, t.source_id AS spine_id,\n",
      "       cast(row_number() OVER (PARTITION BY r.seg_id ORDER BY r.lo)\n",
      "            AS INTEGER) AS spine_piece,\n",
      paste0("       t.", DBI::dbQuoteIdentifier(con, attrs), collapse = ",\n"),
      ",\n       t.name_fold,\n",
      "       st_linesubstring(t.geom, r.lo, r.hi) AS geom\n",
      "FROM runs r JOIN ", DBI::dbQuoteIdentifier(con, target),
      " t USING (seg_id)\n",
      "WHERE NOT r.covered\n",
      "  AND (r.hi - r.lo) * r.len_m >= ", cs_num(min_segment_m), ";"))
  }

  # Assigned once the cascade is complete, so it numbers the finished spine.
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE cs_spine AS\n",
    "SELECT row_number() OVER () AS seg_id, *, st_length(geom) AS len_m\n",
    "FROM ", o, " WHERE st_length(geom) > 0;"))
  invisible("cs_spine")
}

#' Tag the finished spine with the years each part of it is present in
#'
#' Coverage is computed against one interval set shared by every vintage, so a
#' segment boundary is a place where *some* vintage changed, and the year set
#' is constant along each emitted segment by construction.
#'
#' This is the pass that does not scale nationally. With no region, the
#' coverage test spilled 18.6 GiB and then 31.8 GiB of DuckDB temporary storage
#' during development and exhausted the disk -- at `threads = 4` and with
#' `preserve_insertion_order = false` alike. The shape of a fix is the trick
#' `cs_build_rescue_index()` already applies to the name rescue: block rule A's
#' `ST_DWithin` on a grid as well. But the cell would have to be near the
#' tolerance rather than 5 km, since a 5 km cell in downtown Toronto holds tens
#' of thousands of arcs and a hash join on it would be worse than the spatial
#' join it replaced. Measure before committing to it.
#'
#' @param con A writable DuckDB connection.
#' @param spine Table from `cs_build_spine()`.
#' @param staged Named list of staged table pairs.
#' @param specs Per-vintage match specs.
#' @param bearing_tol Bearing tolerance in degrees.
#' @param min_segment_m Shortest segment to emit.
#' @param quiet Suppress progress messages.
#' @return The name of the temp table holding the merged, tagged intervals.
#' @keywords internal
#' @noRd
cs_tag_spine <- function(con, spine, staged, specs, bearing_tol,
                         min_segment_m, quiet = FALSE) {
  vintages <- as.integer(names(staged))
  max_tol <- max(vapply(specs, function(s) s$tol, numeric(1)))

  cs_message(quiet, "  cutting the spine ...")
  cs_breakpoints(con, "cs_bp", spine,
                 vapply(staged, function(s) s$match, character(1)),
                 tol = max_tol)
  cs_intervals(con, "cs_iv", spine, "cs_bp", max_len_m = 3 * max_tol)
  cs_interval_points(con, "cs_pt", "cs_iv", spine)

  for (k in seq_along(vintages)) {
    v <- vintages[k]
    cs_message(quiet, "  coverage in ", v, " ...")
    pred <- cs_covered_by_sql("x.mid", "x.az", "x.name_fold", specs[k],
                              bearing_tol, short = "x.piece_m < 15")
    sql <- paste0(
      "SELECT x.seg_id, x.lo, x.hi, x.len_m, ", v, " AS vintage,\n",
      "       ", pred, " AS covered\n",
      "FROM cs_pt x")
    if (k == 1L) {
      DBI::dbExecute(con, paste0(
        "CREATE OR REPLACE TEMP TABLE cs_cov AS\n", sql, ";"))
    } else {
      DBI::dbExecute(con, paste0("INSERT INTO cs_cov\n", sql, ";"))
    }
  }

  # `list(...) FILTER` gives the year set directly; the pipe-joined string is
  # carried alongside because a plain GROUP BY on it answers "how many km were
  # present in exactly these years", which is the question this table exists
  # to answer.
  keyed <- paste0(
    "  SELECT seg_id, lo, hi, any_value(len_m) AS len_m,\n",
    "         array_to_string(list_sort(list(vintage) FILTER (WHERE covered)),\n",
    "                         '|') AS year_key\n",
    "  FROM cs_cov GROUP BY seg_id, lo, hi")

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE cs_merged AS\n",
    cs_merge_runs_sql(keyed, "year_key"), ";"))

  # Absorb slivers. A run boundary that falls a metre from another one would
  # otherwise emit a segment too short to mean anything, and short segments are
  # exactly where a midpoint test is least reliable. Each short piece is folded
  # into the nearest piece that is long enough -- preferring the one before it,
  # then the one after, and falling back to the longest piece on the arc when
  # the whole arc is shorter than the minimum.
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE cs_absorbed AS\n",
    "WITH m AS (\n",
    "  SELECT seg_id, year_key, lo, hi, len_m, (hi - lo) * len_m AS piece_m,\n",
    "         row_number() OVER (PARTITION BY seg_id ORDER BY lo) AS rn\n",
    "  FROM cs_merged\n",
    "), a AS (\n",
    "  SELECT *, coalesce(\n",
    "    max(CASE WHEN piece_m >= ", cs_num(min_segment_m), " THEN rn END)\n",
    "      OVER (PARTITION BY seg_id ORDER BY lo\n",
    "            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),\n",
    "    min(CASE WHEN piece_m >= ", cs_num(min_segment_m), " THEN rn END)\n",
    "      OVER (PARTITION BY seg_id ORDER BY lo\n",
    "            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING),\n",
    "    first_value(rn) OVER (PARTITION BY seg_id ORDER BY piece_m DESC)\n",
    "  ) AS anchor\n",
    "  FROM m\n",
    ")\n",
    "SELECT seg_id, min(lo) AS lo, max(hi) AS hi, any_value(len_m) AS len_m,\n",
    "       max(year_key) FILTER (WHERE rn = anchor) AS year_key\n",
    "FROM a GROUP BY seg_id, anchor;"))

  # Absorption can leave two neighbours agreeing, so run the merge once more.
  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE cs_final AS\n",
    cs_merge_runs_sql("  SELECT seg_id, lo, hi, len_m, year_key FROM cs_absorbed",
                      "year_key"), ";"))
  invisible("cs_final")
}

#' Cut the tagged intervals into the output table
#' @keywords internal
#' @noRd
cs_emit_tnet <- function(con, name, spine, tagged) {
  attrs <- cs_target_schema()$column
  tbl <- DBI::dbQuoteIdentifier(con, cs_tnet_table_name(name))

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TABLE ", tbl, " AS\n",
    "SELECT row_number() OVER (ORDER BY s.spine_vintage, s.spine_id, f.seg_id,\n",
    "                          f.lo) AS segment_id,\n",
    "       s.spine_vintage, s.spine_id, s.spine_piece,\n",
    "       f.lo AS spine_lo, f.hi AS spine_hi,\n",
    "       cast(string_split(f.year_key, '|') AS INTEGER[]) AS years,\n",
    "       f.year_key,\n",
    "       cast(len(string_split(f.year_key, '|')) AS INTEGER) AS n_years,\n",
    "       cast(list_min(cast(string_split(f.year_key, '|') AS INTEGER[]))\n",
    "            AS INTEGER) AS first_year,\n",
    "       cast(list_max(cast(string_split(f.year_key, '|') AS INTEGER[]))\n",
    "            AS INTEGER) AS last_year,\n",
    paste0("       s.", DBI::dbQuoteIdentifier(con, attrs), collapse = ",\n"),
    ",\n",
    "       st_length(st_linesubstring(s.geom, f.lo, f.hi)) AS len_m,\n",
    "       st_linesubstring(s.geom, f.lo, f.hi)::GEOMETRY AS geom\n",
    "FROM ", DBI::dbQuoteIdentifier(con, tagged), " f\n",
    "JOIN ", DBI::dbQuoteIdentifier(con, spine), " s USING (seg_id)\n",
    "WHERE f.year_key <> ''\n", cs_not_superseded_sql(), ";"))

  dropped <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n, coalesce(sum(\n",
    "  st_length(st_linesubstring(s.geom, f.lo, f.hi))), 0) AS m\n",
    "FROM ", DBI::dbQuoteIdentifier(con, tagged), " f\n",
    "JOIN ", DBI::dbQuoteIdentifier(con, spine), " s USING (seg_id)\n",
    "WHERE f.year_key <> '' AND NOT (", trimws(cs_not_superseded_sql(TRUE)),
    ");"))

  DBI::dbExecute(con, paste0(
    "CREATE INDEX ", DBI::dbQuoteIdentifier(
      con, paste0("idx_", cs_tnet_table_name(name), "_geom")),
    " ON ", tbl, " USING RTREE (geom);"))
  invisible(list(table = cs_tnet_table_name(name),
                 n_dropped = as.integer(dropped$n[1]),
                 m_dropped = as.numeric(dropped$m[1])))
}

#' The rule that keeps `last_year == spine_vintage` exactly true
#'
#' A piece contributed to the spine by an older vintage was put there because
#' its midpoint tested as uncovered by every newer one. Tagging then re-cuts
#' the finished spine on breakpoints drawn from *all* vintages, so the piece is
#' tested again at different midpoints -- and a handful of them, about 0.2% in
#' measurement, come back covered after all. The two tests are the same
#' predicate; only the points differ.
#'
#' Such a piece is redundant rather than informative: the newer vintage covers
#' that ground, so the newer vintage's own spine already carries it, with
#' better geometry. Emitting it would both double-count the length and break
#' the guarantee that a segment's geometry comes from the newest year it exists
#' in. It is dropped, and the count is recorded on the build.
#'
#' @param bare Return the predicate without the leading `AND`.
#' @return A SQL predicate string.
#' @keywords internal
#' @noRd
cs_not_superseded_sql <- function(bare = FALSE) {
  p <- paste0("list_max(cast(string_split(f.year_key, '|') AS INTEGER[]))",
              " <= s.spine_vintage")
  if (bare) p else paste0("  AND ", p, "\n")
}

#' Build the segment-to-source crosswalk
#'
#' README item 2 in its own right: for every emitted segment and every year it
#' is present in, which arc of that year's file it corresponds to, how far away
#' that arc is, whether the names agree, and which of the two matching rules
#' found it. Recording the rule is what keeps the same-name rescue auditable --
#' a caller who distrusts it can drop `match_kind = 'name_rescue'` and see
#' exactly what it was carrying.
#'
#' @param con A writable DuckDB connection.
#' @param name Build name.
#' @param staged Named list of staged table pairs.
#' @param specs Per-vintage match specs.
#' @param bearing_tol Bearing tolerance in degrees.
#' @param quiet Suppress progress messages.
#' @return The crosswalk table name, invisibly.
#' @keywords internal
#' @noRd
cs_emit_crosswalk <- function(con, name, staged, specs, bearing_tol,
                              quiet = FALSE) {
  vintages <- as.integer(names(staged))
  tbl <- DBI::dbQuoteIdentifier(con, cs_tnet_src_table_name(name))
  main <- DBI::dbQuoteIdentifier(con, cs_tnet_table_name(name))

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TEMP TABLE cs_xw_pts AS\n",
    "SELECT segment_id, spine_vintage, years, name_fold, mid,\n",
    "       cs_local_az(geom, mid) AS az\n",
    "FROM (SELECT segment_id, spine_vintage, years,\n",
    "             ", cs_name_fold_sql(), " AS name_fold,\n",
    "             geom, st_lineinterpolatepoint(geom, 0.5) AS mid\n",
    "      FROM ", main, ");"))

  DBI::dbExecute(con, paste0(
    "CREATE OR REPLACE TABLE ", tbl, " (\n",
    "  segment_id BIGINT, vintage INTEGER,\n",
    "  source_file VARCHAR, source_id VARCHAR, src_name VARCHAR,\n",
    "  match_kind VARCHAR, dist_m DOUBLE, name_match BOOLEAN,\n",
    "  bearing_diff DOUBLE, csduid VARCHAR, csdname VARCHAR\n);"))

  for (k in seq_along(vintages)) {
    v <- vintages[k]
    spec <- specs[[k]]
    cs_message(quiet, "  crosswalk for ", v, " ...")

    # Candidates come from the two rules separately rather than from one join
    # at `max(tol, name_far)`: a 200 m spatial join is an order of magnitude
    # more pairs than the tolerance needs, and the rescue side is cheaper
    # through its grid-blocked index anyway.
    cand_cols <- paste0(
      "  SELECT e.segment_id, e.spine_vintage, e.name_fold AS sname, e.az,\n",
      "         o.source_file, o.source_id, o.name AS src_name,\n",
      "         o.name_fold, o.csduid_l, o.csdname_l,\n",
      "         st_distance(o.geom, e.mid) AS d,\n",
      "         cs_local_az(o.geom, e.mid) AS oaz\n")
    cand <- paste0(
      cand_cols,
      "  FROM cs_xw_pts e\n",
      "  JOIN ", DBI::dbQuoteIdentifier(con, staged[[k]]$match), " o\n",
      "    ON st_dwithin(o.geom, e.mid, ", cs_num(spec$tol), ")\n",
      "  WHERE list_contains(e.years, ", v, ")")
    if (!is.null(spec$rescue)) {
      cand <- paste0(
        cand, "\n  UNION ALL\n", cand_cols,
        "  FROM cs_xw_pts e\n",
        "  JOIN ", spec$rescue, " o\n",
        "    ON o.name_fold = e.name_fold\n",
        "   AND o.cx = ", cs_cell_sql("e.mid", "x"), "\n",
        "   AND o.cy = ", cs_cell_sql("e.mid", "y"), "\n",
        "   AND st_dwithin(o.geom, e.mid, ", cs_num(spec$name_far), ")\n",
        "  WHERE list_contains(e.years, ", v, ") AND e.name_fold <> ''")
    }

    DBI::dbExecute(con, paste0(
      "INSERT INTO ", tbl, "\n",
      "WITH cand AS (\n", cand, "\n", "), ranked AS (\n",
      "  SELECT *,\n",
      "         least(abs(oaz - az), 360 - abs(oaz - az),\n",
      "               abs(abs(oaz - az) - 180)) AS bdiff,\n",
      "         CASE WHEN d <= ", cs_num(spec$tol),
      " AND cs_bearing_agree(oaz, az, ", cs_num(bearing_tol),
      ") THEN 0 ELSE 1 END AS tier\n",
      "  FROM cand\n",
      "  WHERE (d <= ", cs_num(spec$tol), " AND cs_bearing_agree(oaz, az, ",
      cs_num(bearing_tol), "))\n",
      "     OR (name_fold = sname AND name_fold <> '' AND d <= ",
      cs_num(spec$name_far), ")\n",
      "), best AS (\n",
      # A single numeric ordering key rather than a row comparison: it puts
      # every rule-A candidate ahead of every rescue candidate, and orders
      # within each by distance.
      "  SELECT segment_id, any_value(spine_vintage) AS spine_vintage,\n",
      "         arg_min(source_file, tier * 1e9 + d) AS source_file,\n",
      "         arg_min(source_id, tier * 1e9 + d) AS source_id,\n",
      "         arg_min(src_name, tier * 1e9 + d) AS src_name,\n",
      "         arg_min(d, tier * 1e9 + d) AS dist_m,\n",
      "         arg_min(tier, tier * 1e9 + d) AS tier,\n",
      "         arg_min(name_fold = sname, tier * 1e9 + d) AS name_match,\n",
      "         arg_min(bdiff, tier * 1e9 + d) AS bearing_diff,\n",
      "         arg_min(csduid_l, tier * 1e9 + d) AS csduid,\n",
      "         arg_min(csdname_l, tier * 1e9 + d) AS csdname\n",
      "  FROM ranked GROUP BY segment_id\n",
      ")\n",
      "SELECT segment_id, ", v, " AS vintage, source_file, source_id,\n",
      "       src_name,\n",
      "       CASE WHEN spine_vintage = ", v, " THEN 'spine'\n",
      "            WHEN tier = 1 THEN 'name_rescue'\n",
      "            WHEN name_match THEN 'geometry+name'\n",
      "            ELSE 'geometry' END AS match_kind,\n",
      "       dist_m, name_match, bearing_diff, csduid, csdname\n",
      "FROM best;"))
  }
  invisible(cs_tnet_src_table_name(name))
}

#' Drive a whole build
#' @keywords internal
#' @noRd
cs_build_tnet <- function(con, name, vintages, within = NULL,
                          tolerance = NULL, bearing_tol = 25,
                          name_far_m = 200, min_segment_m = 10,
                          roads_only = TRUE, region_note = NULL,
                          quiet = FALSE) {
  # `NULL` means every vintage the cache holds. Any two or more of them are a
  # legal build -- there is nothing special about the census years, and the
  # spacing between them need not be even.
  vintages <- if (is.null(vintages)) cs_db_vintages(con) else vintages
  vintages <- sort(unique(vapply(vintages, cs_check_vintage, integer(1))),
                   decreasing = TRUE)
  if (length(vintages) < 2L) {
    stop("`vintages` must name at least two years to compare; got ",
         if (length(vintages)) paste(vintages, collapse = ", ") else "none",
         ".", call. = FALSE)
  }
  missing <- vintages[!vapply(vintages, function(v) cs_db_has_vintage(con, v),
                              logical(1))]
  if (length(missing)) {
    stop("Vintage", if (length(missing) > 1L) "s", " ",
         paste(missing, collapse = ", "), " ",
         if (length(missing) > 1L) "are" else "is", " not imported. ",
         "`build_temporal_network()` imports as needed; ",
         "`cs_build_tnet()` does not.", call. = FALSE)
  }
  started <- Sys.time()

  region <- cs_region_wkt(within, halo_m = max(name_far_m, 3 * 40))
  cs_message(quiet, "Staging ", length(vintages), " vintages ...")
  staged <- stats::setNames(lapply(vintages, function(v) {
    s <- cs_tnet_stage(con, v, region, roads_only = roads_only,
                       name_far_m = name_far_m)
    list(match = unname(s["match"]), spine = unname(s["spine"]),
         rescue = unname(s["rescue"]))
  }), as.character(vintages))

  # Tolerances. Each older vintage is calibrated against the newest, which is
  # the reference the whole build is expressed in. The newest vintage's own
  # tolerance is the loosest of those, because the arcs it is asked about are
  # spine pieces contributed by the older vintages, and they carry the older
  # vintages' positional error.
  cal <- list()
  tol <- stats::setNames(rep(NA_real_, length(vintages)),
                         as.character(vintages))
  if (is.null(tolerance)) {
    for (k in seq_along(vintages)[-1]) {
      v <- vintages[k]
      cs_message(quiet, "Calibrating ", v, " against ", vintages[1], " ...")
      c_v <- cs_calibrate_tolerance(con, staged[[k]]$match,
                                    staged[[1]]$match)
      cal[[as.character(v)]] <- c_v
      tol[as.character(v)] <- c_v$tolerance_m
    }
    tol[1] <- max(tol[-1])
  } else if (!is.null(names(tolerance))) {
    tol[names(tolerance)] <- as.numeric(tolerance)
    if (anyNA(tol)) {
      stop("`tolerance` is named but does not cover every vintage; missing ",
           paste(names(tol)[is.na(tol)], collapse = ", "), ".", call. = FALSE)
    }
  } else {
    tol[] <- as.numeric(tolerance[1])
  }
  cs_message(quiet, "Tolerances (m): ",
             paste0(names(tol), "=", round(tol, 1), collapse = ", "))

  specs <- lapply(seq_along(vintages), function(k) {
    list(src = DBI::dbQuoteIdentifier(con, staged[[k]]$match),
         rescue = if (is.na(staged[[k]]$rescue)) NULL else
           DBI::dbQuoteIdentifier(con, staged[[k]]$rescue),
         tol = unname(tol[k]), name_far = name_far_m)
  })

  cs_message(quiet, "Building the spine ...")
  spine <- cs_build_spine(con, "cs_spine_raw", staged, specs, bearing_tol,
                          min_segment_m, quiet = quiet)
  tagged <- cs_tag_spine(con, spine, staged, specs, bearing_tol,
                         min_segment_m, quiet = quiet)

  cs_message(quiet, "Writing ", cs_tnet_table_name(name), " ...")
  emitted <- cs_emit_tnet(con, name, spine, tagged)
  if (emitted$n_dropped > 0) {
    cs_message(quiet, "Dropped ", emitted$n_dropped, " superseded pieces (",
               round(emitted$m_dropped), " m).")
  }
  cs_emit_crosswalk(con, name, staged, specs, bearing_tol, quiet = quiet)

  summary <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n, sum(len_m) / 1000 AS km FROM ",
    DBI::dbQuoteIdentifier(con, cs_tnet_table_name(name))))

  cs_builds_write(con, name, list(
    tnet_schema_version = as.character(cs_tnet_schema_version()),
    vintages = paste(sort(vintages), collapse = ","),
    tolerance_m = jsonlite::toJSON(as.list(tol), auto_unbox = TRUE),
    bearing_tol = as.character(bearing_tol),
    name_far_m = as.character(name_far_m),
    min_segment_m = as.character(min_segment_m),
    # `roads_only` may be a vector of build statuses; `canstreet_builds` is an
    # EAV table holding one string per key, so it is joined rather than kept.
    roads_only = paste(as.character(roads_only), collapse = ","),
    n_dropped_superseded = as.character(emitted$n_dropped),
    m_dropped_superseded = as.character(round(emitted$m_dropped, 1)),
    region_wkt = if (is.null(region)) NA_character_ else region$region,
    region_note = region_note %||% NA_character_,
    calibration = jsonlite::toJSON(lapply(cal, function(x) {
      list(tolerance_m = x$tolerance_m, n_pairs = x$n_pairs,
           d_precision = x$d_precision %||% NA,
           recall = as.list(x$recall %||% NULL),
           disagree = as.list(x$disagree %||% NULL),
           dx = x$dx, dy = x$dy, calibrated = x$calibrated)
    }), auto_unbox = TRUE, null = "null"),
    n_segments = as.character(summary$n[1]),
    total_km = as.character(round(summary$km[1], 3)),
    package_version = as.character(utils::packageVersion("canstreet")),
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    build_seconds = as.character(round(as.numeric(
      difftime(Sys.time(), started, units = "secs")), 1)),
    licence = "Statistics Canada Open Licence"
  ))

  for (t in c("cs_bp", "cs_iv", "cs_pt", "cs_cov", "cs_merged", "cs_absorbed",
              "cs_final", "cs_spine", "cs_spine_raw", "cs_xw_pts",
              stats::na.omit(unlist(lapply(staged, unlist),
                                     use.names = FALSE)))) {
    DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ",
                               DBI::dbQuoteIdentifier(con, t), ";"))
  }

  cs_message(quiet, "Built ", format(summary$n[1], big.mark = ","),
             " segments, ", format(round(summary$km[1]), big.mark = ","),
             " km.")
  invisible(summary$n[1])
}
