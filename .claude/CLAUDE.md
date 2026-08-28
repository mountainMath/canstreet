# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`canstreet` is an R package (by Jens von Bergmann / MountainMath) for downloading and processing
**historical Statistics Canada road/street network files**, so the evolution of the Canadian road
network over time can be analysed reproducibly.

**v1 and v2 are implemented and `R CMD check` is clean.** v1 downloads, harmonizes and serves the
1991–2025 series; v2 matches segments across vintages and writes a temporally unified network — see
*The temporal network* below.

## Commands

Development uses devtools (the `.Rproj` sets `PackageUseDevtools: Yes`). From the package root:

```r
devtools::load_all()            # load package for interactive work (Cmd+Shift+L in RStudio)
devtools::document()            # regenerate NAMESPACE + man/ from roxygen comments
devtools::test()                # run all tests
devtools::test(filter = "db")   # run only tests/testthat/test-db.R
devtools::check()               # full R CMD check (run before any release)
```

The test suite is gated on `NOT_CRAN`, so from the shell:

```sh
R -q -e 'Sys.setenv(NOT_CRAN="true"); devtools::load_all(); testthat::test_local()'
R -q -e 'devtools::check(env_vars = c(NOT_CRAN = "true"))'
```

Vignettes are **precomputed**: edit `vignettes/*.Rmd.orig`, then run `Rscript vignettes/precompute.R`
and commit the resulting `.Rmd` and its `canstreet-*.png` figures. The script refuses to run without
a cache path set, because the vignettes query real national files. Never edit the `.Rmd` by hand.

## Architecture

Data flows manifest → download → harmonize → DuckDB → lazy `tbl`. One module per concern:

| File | Role |
|---|---|
| `R/sources.R` | **The manifest.** One row per vintage; every other module reads it. Adding a vintage is a data edit here, not a code change. |
| `R/download.R` | `canstreet_download()`, archive extraction |
| `R/abacus.R` | Dataverse manifest resolution and file access for the pre-2005 vintages |
| `R/db.R` | Connection cache, spatial extension, storage CRS, metadata table, `segments` view |
| `R/import.R` | The harmonizer: target schema, alias resolution, address normalization |
| `R/api.R` | `get_road_network()`, `collect_road_network()`, `export_road_network()`, `canstreet_schema()` |
| `R/cache_path.R` | `CANSTREET_CACHE_PATH` → `canstreet.cache_path` option → `tempdir()` |
| `R/cache_mgmt.R` | `list_canstreet_cache()`, `remove_canstreet_cache()` |
| `R/tnet.R` | The cross-vintage matcher: calibration, spine cascade, interval cutting, emit |
| `R/tnet_api.R` | `build_temporal_network()` and the six other `*_temporal_network*()` functions |

**Sources.** Statistics Canada serves 2001 and 2005–2025 directly; only 1991 and 1996 come from the
Abacus Data Network (UBC), whose Dataverse API needs no credentials for the `statcan-public`
collection.
Abacus's DMTI Spatial collection is licence-restricted — **never automate against it.** Borealis has
no StatCan street/road network files. Nothing digital exists for 1971 or 1986 in any repository
searched; if those ever arrive it will be as a custom StatCan request that MountainMath hosts.

**Storage.** One DuckDB file at `<cache_path>/canstreet.duckdb`, holding one table per vintage
(`snf_1996`, `rnf_2021`) plus a `segments` UNION ALL BY NAME view, with the source zips kept under
`<cache_path>/downloads/<vintage>/` so the database is always rebuildable without re-downloading
~7 GB. One table per vintage because `DROP TABLE` is instant while DuckDB's `DELETE` does not reclaim
file space. All geometry is reprojected to EPSG:3347 (NAD83 / StatCan Lambert) on import, which is
what makes `len_m` and every distance metres for every vintage. A temporal build adds two more tables
to the same file, `tnet_<slug>` and `tnet_<slug>_src`, described in a `canstreet_builds` EAV table —
kept separate from `canstreet_metadata`, whose key column is `vintage INTEGER` and which
`cs_db_vintages()` scans.

**Harmonization is alias-driven, never era-branched.** The schema eras do not map cleanly onto
vintages — 2005 spells the identifier `NGD_ID` though its neighbours do not — so `cs_target_schema()`
lists case-insensitive aliases per target column and `cs_harmonize_sql()` resolves each against the
columns actually present. A column a vintage lacks becomes `NULL` throughout it, which is what keeps
the union view legal. `schema_era` in the manifest is advisory only; do not dispatch on it.

## Conventions

- **Roxygen is the source of truth for `NAMESPACE` and `man/`.** `devtools::document()` overwrites
  both — never hand-edit either.
- 2-space indent, no tabs, UTF-8, trailing whitespace stripped (per `.Rproj`).
- `cache_path = canstreet_cache_path()` written literally in every exported signature; argument order
  identity → selection → behaviour (`refresh`, `quiet`) → `cache_path` last.
- User-facing functions return tibbles, or a lazy `dplyr::tbl()` that the caller collects explicitly.
- Network failure raises a classed `canstreet_network_error` so an offline session degrades instead
  of erroring opaquely (CRAN policy). Tests mock `cs_download` / `cs_url_is_available` rather than
  touching the network — **no test may require the internet.**
- StatCan data is redistributed under the Statistics Canada Open Licence — cite it in `DESCRIPTION`
  and in the docs of any function that downloads data.

## Sibling packages as prior art

The author maintains a family of StatCan-data packages in `/Users/jens/R` — `canpumf` (whose
`robust_unzip()` and download wrapper this package adapts), `cansim`, `cancensus`, and `cangeocode`
(whose `R/geo_helpers.R` establishes the untagged-geometry + metadata-CRS pattern). Match their
established patterns rather than inventing new ones.

## Gotchas, each of which cost real time

- **`ENCODING=ISO-8859-1` is required** on `ST_Read` of every RNF shapefile. The `.dbf` is Latin-1
  with no `.cpg`; without it the first accented street name aborts with `invalid code point detected
  in Utf8Proc::UTF8ToCodepoint` — surfacing at the first string operation, not at read, so it looks
  like a string-folding problem.
- **StatCan serves a missing release as a soft 404**: 302 → a ~4 KB `text/html` page with `200 OK`.
  `download.file()` would save that as a `.zip`. Probe content-type *and* length before committing.
- **Geometry must be stored untagged.** DuckDB refuses `CREATE INDEX ... USING RTREE` over a
  `GEOMETRY('EPSG:xxxx')` column, so the CRS lives in `canstreet_metadata` and is reapplied on the
  way out (export, reprojected collect).
- **`ST_SetCRS` needs a constant**, so the CRS cannot be a macro parameter — hence `cs_to_storage_sql()`
  builds the SQL in R rather than a `cs_to_storage(g, from_crs)` macro.
- **`always_xy = TRUE` on every transform.** EPSG:4269/4267 declare lat/long axis order; without the
  flag DuckDB reads a longitude of -123 as a latitude and silently returns infinity.
- **A spatial filter must embed its geometry as a WKT literal**, not a bound parameter — DuckDB's
  `RTREE_INDEX_SCAN` requires a constant on the other side of `ST_Intersects`. Verify with `EXPLAIN`.
- **Three null sentinels on top of real `NULL`**: `''` everywhere, `N/A` in the modern RNF, and a bare
  `_` throughout 2001. Zero and negative address ranges are dominant, not edge cases. 2001 adds a
  fourth by accident: its coverage declares the address columns integer but stores the string `NA`
  in them, so GDAL parses those to **0** and warns once per field (`Value 'NA    ' of field
  ARC.ADDR_TO_LEFT parsed incompletely to integer 0`). That lands on the zero sentinel
  `cs_normalize_address_ranges()` already clears, so the three warnings are left visible rather than
  muffled — unlike the ten `Normalized/laundered field name` ones, which are expected truncation.
- **The 1991/1996 `.prj` is degenerate** (`GEOGCS["Unknown", DATUM["D_NAD_27_Canada", ...]]`); assign
  EPSG:4267 explicitly.
- **1991 ships Lambert twins**: `LSNF*` and `OT_HULL` duplicate `GSNF*` and `HULL_OTT`. The manifest's
  `file_exclude` keeps them out; without it Halifax and Ottawa-Hull double-count.
- **2001 now comes from StatCan**, not Abacus: `grnf000r01a_e.zip` under the 2011 `rnf-frr/files-fichiers/`
  path (verified 200 / zip / 397 MB; the `…01g…`, `lrnf…01a…` and `…01a_f` spellings all return the
  soft-404 signature, as do the equivalent 1991 and 1996 paths — so only 2001 moves). The old Abacus
  route is no longer used; if you ever go back to it, note that its `mp` files are block polygons and
  the `ml` shapefile is the road network.
- **2001 is not a shapefile, and the `a` in its filename does not mean it is.** The archive holds one
  1.5 GB ArcInfo interchange coverage, `grnf000r02a_e.e00` (yes, `02` — released 2002), plus a PDF.
  GDAL reads it through the **AVCE00** driver; a coverage names its layers by geometry, so `ARC` is
  the network (2,053,112 linestrings) and `CNT`, `LAB`, `PAL` are the polygon side.
- **Do not read the coverage directly — convert it once.** `ST_Read` over AVCE00 scans about **230
  rows a second** (a `LIMIT 50000` took 13.6 minutes), which is over two hours for 2001, and
  `cs_import_vintage()` opens the source twice (`DESCRIBE`, then `INSERT`). The format is sequential
  ASCII with no random access, so `LIMIT` buys nothing. `ogr2ogr` writes the same layer as a
  shapefile in **90 seconds**, after which the ordinary shapefile path scans all 2.05M rows in 16 s.
  `cs_coverage_to_shapefile()` in `R/helpers.R` does this, and `cs_resolve_line_source()` calls it
  when it finds a `.e00`. The shapefile is written beside the coverage inside the extraction
  directory, which `cs_import_vintage()` deletes on exit, so it costs 90 s per import rather than
  being cached — the source zip is what the cache keeps, as for every other vintage.
- **The coverage's `.dbf` is Latin-1 and GDAL will not tell you.** `LC_ALL=C grep` reported no
  high bytes — wrongly, that shell's `grep` is `ugrep`; `LC_ALL=C tr -dc '\200-\377' | wc -c` finds
  **60,918**, mostly `0xE9` (31,614 — the acute e of *Vérendrye*), then `0xE8`, `0xC9`, `0xF4`,
  `0xE7`. AVCE00 has **no open options at all**, so no `ENCODING` can be passed to the driver; GDAL
  passes the bytes through unrecoded while believing them UTF-8. The conversion therefore writes
  `-lco ENCODING=` (empty), which keeps the raw bytes and emits no `.cpg` — exactly the file every
  other RNF vintage ships, read back with the `ENCODING=ISO-8859-1` `cs_st_read_sql()` already
  applies. Let GDAL write its default `.cpg` instead and it labels the bytes UTF-8, and the first
  accented street name aborts the scan.
- **The 2001 coverage spells its address columns in full** — `ADDR_FM_LEFT`, not the shapefile
  vintages' 10-character `ADDR_FM_LE`. It does not matter in the end, because the conversion to
  shapefile truncates them back to the 10-character spellings the alias table already carries, but
  do not be surprised by either. It carries `ARC_ID` (not `RB_UID`, as the Abacus deposit did),
  unique across all 2,053,112 rows, and `RANK1`–`RANK4` rather than a plain `RANK`, so `rank` is
  NULL for 2001 until someone documents what those four ranks mean.
- **Never use the 2025 GeoPackage** — 13 CircularStrings that DuckDB's spatial extension rejects.
  Always take the `a` (shapefile) variant.
- **DuckDB spatial 1.5.4 has no `ST_Hausdorff`, `ST_FrechetDistance`, `ST_MaxDistance`, `ST_Split`,
  `ST_Snap`, `ST_Segmentize` or `ST_Relate`.** Cross-vintage geometry comparison is built from
  `ST_LineLocatePoint` (measure), `ST_LineSubstring` (cut), `ST_LineInterpolatePoint` and `ST_Azimuth`
  instead. Check before reaching for a PostGIS function by memory.
- **`generate_series` does not bind in a scalar position** — subdividing an interval into `k` pieces
  needs `unnest(range(0, k))`.
- **A whole-arc `ST_Azimuth(start, end)` is meaningless for a long arc**: on a 5 km curve it describes
  a chord no part of the road follows. `cs_local_az(g, p)` measures the bearing on a ±25 m window
  around the projection of `p`; `cs_bearing_agree` folds by 180° so reversed digitization agrees.
- **`normalizePath()` leaves a non-existent leaf alone**, so keying a cache on a database file path
  gives one key before the file exists and another after (macOS `/var` → `/private/var`). `cs_conn_key()`
  keys on the resolved *directory*.

## Verified data facts

Established by reading the actual files, not the documentation. Trust these over the reference guides.

- **Identifier spellings**: `arc_id` (1991/1996), `RB_UID` (2001–2010), `NGD_ID` (2005), `NGD_UID`
  (2011+), `NGDUID` (2016/2017 — no underscore).
- **2021 has no `CMAUID` columns**; 2011 and 2016 do. An empty `cmauid_l` for 2021 is correct.
- **2006 carries more total length than 2021** (1.33M vs 1.17M km) because it holds far more very long
  arcs — 22,486 over 5 km against 2021's 13,055. Not an import bug; neither table has a duplicate
  geometry.
- Segment counts: 1996 = 629,574 (urban only); 2001 = 2,053,112; 2006 = 1,869,564; 2011 = 1,973,932;
  2016 = 2,163,058; 2021 = 2,242,117.
- 1991 and 1996 cover **urban areas only**; 2001 onward is national. 2001 imports 2,053,112 arcs /
  1,736,503 km as read, 1,329,337 km once the non-road classes above are dropped.
- **The 1991/1996 SNF is a full topographic base, not a road network.** `class IS NULL` is an ordinary
  street (503,150 arcs in 1996; 96% of arcs are typed, 76% addressed); a non-null `class` names a
  *feature type*, of which only twelve are roads — see `cs_snf_road_classes()`. Watercourses, rail,
  hydro lines, EA boundaries and the outlines of parks, golf courses and airports account for roughly
  51,000 of the 1996 file's ~160,000 km. Leaving them in reports every river as a retired road: the
  Calgary pilot's implausible "retired 1996 road" fell from 56.6 km to 2.60 km once they were
  filtered. Bridge arcs were checked and do *not* duplicate the street underneath.
- **2001's arc layer carries the census boundary topology too**, which is the coverage's equivalent of
  the SNF problem. Its `class` is mostly a numeric feature code (1011 is the ordinary street, 688,063
  arcs; 1003/1015/1016/1020/1022/1306 are the highway families) but three codes are not road:
  **`BO`** (167,916 arcs, **388,345 km**), **`1536`** (1,625 arcs, 18,650 km) and **`SB`** (2,611
  arcs, 171 km). None of the three has a single named, typed or addressed arc; `1536`'s longest arcs
  run along 141°W and across 85–87°N — the Yukon–Alaska meridian and the Arctic Ocean limit — and in
  Calgary only 60 of 1,057 `BO` arcs come within 10 m of a road, so they are separate geometry, not
  block boundaries laid along street centrelines. Dropping the three leaves **1,329,337 km** against
  2006's 1,326,099 km, 0.24% apart: the whole surplus was topology. `cs_rnf_2001_nonroad_classes()`
  names them and `cs_road_class_sql()` inverts the predicate for 2001 — it says what to *drop*, where
  the SNF branch says what to keep, because for 2001 everything else is road. `1307` (346 arcs,
  686 km, unnamed) stays: it sits in the same NWT and Yukon interior as `1306`, whose arcs are the
  Klondike, Alaska and Canol highways.
- **2006's long arcs are coarsely generalized, 2021's are finely digitized.** Of 30,759 2006 Calgary
  arcs, 6,406 fail to match a 2021 arc, and they are systematically long and multi-vertex (p90 length
  484.7 m vs 311.8 m matched; 3.58 vertices vs 2.85, rising to 10.5 in the 1–5 km bucket): Deerfoot
  and Glenmore Trail, Township and Range Roads, numbered highways. The road is there; the 2006 chord
  simply departs from it. This is the same fact as "2006 carries more total length than 2021", and it
  is why the name rescue exists.
- **Positional error between vintages is noise, not a registration shift.** Same-name 2006↔2021 pairs:
  mean dx 0.6 m, dy −1.28 m (1996: 1.16, 4.82) but sd ≈ 13 m in both axes, median midpoint
  displacement 12.6 m. No affine correction is warranted; a generous tolerance is. A mean displacement
  over 10 m raises a warning, since that *would* indicate a shift this design does not correct for.
- **2016 and 2021 share their base geometry.** Their calibrated recall p50 is 8e-7 m, so 2016 clamps
  to the tolerance floor. 1996/2006/2011 hit the *upper* clamp of 40 m because `name_disagree` stays
  flat (0.12→0.14) all the way out — the bound is binding, not the data.

## The temporal network (v2)

`build_temporal_network()` writes `tnet_<slug>` — one row per harmonized segment, tagged with the
years it is present in — plus `tnet_<slug>_src`, the segment-to-source crosswalk. The algorithm lives
in `R/tnet.R`; these are the parts that are load-bearing rather than incidental.

**Newest-first spine cascade.** The newest requested vintage's arcs are laid down whole as the spine.
Each earlier vintage in descending order contributes only the parts of its arcs that no newer vintage
already covers. This is what makes "prefer the newer geocoding" structural rather than a post-hoc
preference, and it yields the invariant **`last_year == spine_vintage`** for every emitted row.

**One predicate, defined once.** "Is point *p* on a road that exists in vintage *v*?" is asked when
finding an old arc's uncovered residual and again when testing the finished spine's coverage. If the
two ever differ the invariant breaks, so both call `cs_match_predicate_sql()`. Crucially,
`cs_covered_by_sql()` ORs the predicate over *each newer vintage's own match table with its own
tolerance*, never over a merged pool — a merged pool would let a 2021-calibrated tolerance decide a
2006 question.

**Two rules, both recorded.** Rule A is `ST_DWithin` within the calibrated tolerance plus local
bearing agreement; rule B ("name rescue") is exact folded-name equality within `name_far_m`
(default 200 m). Rule B exists because older files digitize long rural and highway arcs as a coarse
chord that departs from the road by more than any sane tolerance — without it Calgary reports
~1,180 km of spurious road loss for 2006→2021. `match_kind` in the crosswalk separates them, so a
caller who distrusts the rescue can drop it.

**Calibration keys on `name_disagree`, not on coverage.** The coverage-versus-tolerance curve is
smooth and has no knee, so it cannot choose a tolerance. `name_disagree` — the share of arcs whose
*nearest* arc within *d* carries a different name — stays flat while the tolerance absorbs positional
noise and climbs once it reaches the next street. Intersected with the recall p90 and clamped to
[10, 40] m.

**Cutting is by linear reference.** Nearby source-arc endpoints are projected onto the spine with
`ST_LineLocatePoint`, each interval's midpoint is tested, adjacent intervals with an identical year
set are merged by the gap-and-island trick, and geometry is cut with `ST_LineSubstring`. Arc-to-arc
matching was measured and does not work: requiring both endpoints and the midpoint within 20 m of a
single arc matches 35% of 2006 Calgary arcs.

**Tagging can undo the cascade, so emit drops the residue.** Tagging re-cuts the spine on the
*unified* breakpoints, so a residual piece contributed by an older vintage gets retested at different
midpoints and can come back covered by a newer one. `cs_not_superseded_sql()` drops those at emit
(137 pieces / 3.6 km for Calgary) and the count is recorded on the build. Without it, 9 of 3,744 rows
violated the invariant.

**Halo, then clip.** Sources are staged against the region buffered outward by
`max(name_far_m, 3 * tol)`; only the spine is restricted to the region proper. Without the halo a
road on the CMA edge has its newer counterpart clipped away and reads as retired — a boundary
artefact that looks exactly like a finding. Spine arcs are then clipped with
`unnest(ST_Dump(ST_Intersection(...)))` so `sum(len_m)` is comparable across years.

**Regions are stamped, never filtered.** One fixed polygon across every year. StatCan reuses `CSDUID`
across boundary revisions, and 1996, 2001 and 2006 carry no region columns at all (2001's are all
NULL over all 2,053,112 rows). Each vintage's own
`csduid_l` still goes to the crosswalk, which is what makes `temporal_network_region_drift()`
possible — it recovers the annexation of 54.7 km of road into Airdrie between 2011 and 2016.

**Region scale is fast; national is not solved.** The Calgary CMA over six vintages builds in ~25 s
(75,662 segments, 12,397 km; 1996 4,864 km → 2001 9,254 → 2006 10,145 → 2011 10,643 → 2016 11,088
→ 2021 11,505, and the 1996→2001 jump is coverage, not construction).
National is a different animal, and the v1 benchmark that said "3.1 s" was measuring only breakpoint
derivation plus a bare coverage test — *not* the real predicate — so do not trust it.

Two things were measured properly:

- **The name rescue must be grid-blocked or a national build never finishes.** `name_fold = name_fold`
  alone pairs **956 million** 2006↔2021 arcs before any distance test: 2021 holds 1.94M named arcs over
  only 130,105 distinct folded names, and `MAIN` alone occurs 12,884 times. The uncorrected residual
  pass burned 110 minutes of CPU without completing. `cs_build_rescue_index()` explodes each arc over
  the 5 km cells its `name_far_m`-expanded bbox touches — exact, not approximate, and ~1 row per arc —
  so the join key becomes `(name_fold, cx, cy)`. With it the residual pass completes. Verified
  bit-identical on Calgary: same 74,609 segments, same 12,329 km, same year-set totals.
- **The coverage pass in `cs_tag_spine()` is the remaining blocker.** Nationally it spilled 18.6 GiB,
  then 31.8 GiB of DuckDB temp storage and exhausted the disk, at `threads=4` and
  `preserve_insertion_order=false` alike. So `within = NULL` is *accepted* but not yet the supported
  scale, and the docs say so. If you take this on, the shape of the fix is the same trick again:
  block rule A's `ST_DWithin` on a grid too, but with a cell near the tolerance rather than 5 km — a
  5 km cell in downtown Toronto holds tens of thousands of arcs and a hash join on it would be worse
  than the spatial join. Measure before committing.

DuckDB does plan a cross-vintage `ST_DWithin` as `SPATIAL_JOIN` + `SEQ_SCAN`, ignoring the persistent
RTREE, which is the underlying reason all of this is needed.

**What is deliberately not done.** Address-range agreement as a fourth signal (the columns are only
~55% populated, so it could only ever break ties); node-level topology reconstruction; any assumption
that `NGD_UID` is stable across vintages — nothing documents that it is, and StatCan states arc
positions are "not necessarily consistent with previous versions" (2011 Reference Guide).
