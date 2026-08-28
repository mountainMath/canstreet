# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`canstreet` is an R package (by Jens von Bergmann / MountainMath) for downloading and processing
**historical Statistics Canada road/street network files**, so the evolution of the Canadian road
network over time can be analysed reproducibly.

**v1 is implemented and `R CMD check` is clean.** It downloads, harmonizes and serves the 1991–2025
series. The next piece of work is v2 — see *The v2 task* below.

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

**Sources.** Statistics Canada serves 2005–2025 directly; 1991, 1996 and 2001 come from the Abacus
Data Network (UBC), whose Dataverse API needs no credentials for the `statcan-public` collection.
Abacus's DMTI Spatial collection is licence-restricted — **never automate against it.** Borealis has
no StatCan street/road network files. Nothing digital exists for 1971 or 1986 in any repository
searched; if those ever arrive it will be as a custom StatCan request that MountainMath hosts.

**Storage.** One DuckDB file at `<cache_path>/canstreet.duckdb`, holding one table per vintage
(`snf_1996`, `rnf_2021`) plus a `segments` UNION ALL BY NAME view, with the source zips kept under
`<cache_path>/downloads/<vintage>/` so the database is always rebuildable without re-downloading
~7 GB. One table per vintage because `DROP TABLE` is instant while DuckDB's `DELETE` does not reclaim
file space. All geometry is reprojected to EPSG:3347 (NAD83 / StatCan Lambert) on import, which is
what makes `len_m` and every distance metres for every vintage.

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
  `_` throughout 2001. Zero and negative address ranges are dominant, not edge cases.
- **The 1991/1996 `.prj` is degenerate** (`GEOGCS["Unknown", DATUM["D_NAD_27_Canada", ...]]`); assign
  EPSG:4267 explicitly.
- **1991 ships Lambert twins**: `LSNF*` and `OT_HULL` duplicate `GSNF*` and `HULL_OTT`. The manifest's
  `file_exclude` keeps them out; without it Halifax and Ottawa-Hull double-count.
- **In the 2001 Abacus dataset, `mp` files are block polygons**, not roads. The `ml` shapefile is the
  road network — prefer it to the 396 MB e00.
- **Never use the 2025 GeoPackage** — 13 CircularStrings that DuckDB's spatial extension rejects.
  Always take the `a` (shapefile) variant.
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
- Segment counts: 1996 = 629,574 (urban only); 2006 = 1,869,564; 2021 = 2,242,117.
- 1991 and 1996 cover **urban areas only**; 2001 onward is national.

## The v2 task: matching segments across time

README items 2 and 3 — *"identify common road/street segments across different years even when
geocoding accuracy has changed over time"* and *"create a temporally unified street network dataset
that tags segments according to the years they were present"* — are the next body of work. v1
deliberately stopped short of them so they could be calibrated against real vintages rather than
designed against a guess.

What v1 leaves in place for it: every vintage keeps its own `source_id`, all geometry shares one CRS
in one database so cross-year spatial joins are a single query, and derived crosswalk tables belong
in that same database beside the sources.

Constraints to design against:

- **Do not assume `NGD_UID` is stable across vintages.** Nothing documents that it is, and Statistics
  Canada states arc positions are "not necessarily consistent with previous versions" (2011 Reference
  Guide). Measure persistence empirically first; it is a finding, not an assumption.
- Identifiers change spelling *and* scheme across the series (`arc_id` → `RB_UID` → `NGD_UID`), so
  no identifier joins the whole series on its own.
- Geometry is the more durable signal, but positions shift between releases, arcs get split and
  merged, and the 2006→2021 long-arc difference above shows segmentation itself changes. Expect to
  need tolerant matching (`ST_DWithin`, Hausdorff distance, or shared-endpoint plus name/address
  agreement) rather than geometric equality.
- Benchmarking during v1 found DuckDB plans a cross-vintage `ST_DWithin` join as a `SPATIAL_JOIN`
  with `SEQ_SCAN` on both sides, **ignoring the persistent RTREE**. Budget for that, and consider
  blocking on CSD or a grid key before the spatial predicate.
