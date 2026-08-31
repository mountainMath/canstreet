# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`canstreet` is an R package (by Jens von Bergmann / MountainMath) for downloading and processing
**historical Statistics Canada road/street network files**, so the evolution of the Canadian road
network over time can be analysed reproducibly.

v1 downloads, harmonizes and serves the 1976–2025 series; v2 matches segments across vintages and
writes a temporally unified network. Both are implemented and `R CMD check` is clean.

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

Vignettes are **precomputed**: the sources live in `vignettes.orig/` (plain `.Rmd`, the whole
directory `.Rbuildignore`d), and `Rscript vignettes.orig/precompute.R` knits them into `vignettes/`,
which is what ships. Commit the resulting `.Rmd` and its `canstreet-*.png` figures. Name a subset
(`Rscript vignettes.orig/precompute.R canstreet-vancouver`) while iterating — a full pass rebuilds
both temporal networks. The script refuses to run without a cache path set, because the vignettes
query real national files. Never edit `vignettes/*.Rmd` by hand; each one carries a generated-from
banner saying so.

## Where things are written down

**Each module's header comment is the authoritative account of why that module works the way it
does**, and the roxygen block above a function is the account of that function. Read the header
before changing a module; record a new decision there, next to the code it constrains, rather than
here.

| File | Role |
|---|---|
| `R/sources.R` | **The manifest.** One row per vintage; every other module reads it. Adding a vintage is a data edit here, not a code change. |
| `R/download.R` | `canstreet_download()`, archive extraction |
| `R/abacus.R` | Dataverse manifest resolution and file access for the pre-2001 vintages |
| `R/amf.R` | The Area Master File reader: record layout, COMP-3, chains, `read_amf()` |
| `R/domains.R` | The published `class`/`rank` vocabularies, per vintage, and the `ENUM` retyping |
| `R/classes.R` | Which class values are road, per vintage: the category/status table and the filter predicate |
| `R/db.R` | Connection cache, spatial extension, storage CRS, metadata tables, `segments` view |
| `R/import.R` | The harmonizer: target schema, alias resolution, address normalization |
| `R/helpers.R` | Download probing, `robust_unzip()`, `.e00` staging and byte repair |
| `R/api.R` | `get_road_network()`, `collect_road_network()`, `export_road_network()`, `canstreet_schema()` |
| `R/cache_path.R` | `CANSTREET_CACHE_PATH` → `canstreet.cache_path` option → `tempdir()` |
| `R/cache_mgmt.R` | `list_canstreet_cache()`, `remove_canstreet_cache()` |
| `R/tnet.R` | The cross-vintage matcher: calibration, spine cascade, interval cutting, emit |
| `R/tnet_api.R` | `build_temporal_network()` and the six other `*_temporal_network*()` functions |

Beyond the code:

- `README.md` — the data and coverage narrative: the one series under three names, what the files
  are and are not (not routable, address ranges thin outside the cities), and the citable
  Statistics Canada sources for all of it. This is the user-facing version of the story; do not
  restate it in module comments.
- `vignettes.orig/*.Rmd` — the analyses worked end to end, with their numbers: `canstreet.Rmd`
  (getting started), `canstreet-temporal.Rmd` (a build explained), `canstreet-vancouver.Rmd`
  (45 years over one CMA), `canstreet-renames.Rmd` (classifying name changes).
- `.claude/notes/corpus-facts.md` — measured numbers: per-vintage counts, what the road filter
  costs, positional agreement and calibrated tolerances, build benchmarks, provenance and what
  could not be found anywhere. Consult it before asserting any figure about these files.

## Data flow

manifest → download → harmonize → DuckDB → lazy `tbl`. One DuckDB file at
`<cache_path>/canstreet.duckdb` holds one table per vintage (`snf_1996`, `rnf_2021`) plus a
`segments` UNION ALL BY NAME view, with the source archives kept under
`<cache_path>/downloads/<vintage>/` so the database is always rebuildable without re-downloading
~7 GB. A temporal build adds `tnet_<slug>` and `tnet_<slug>_src`, described in a `canstreet_builds`
table kept separate from `canstreet_metadata`. All geometry is reprojected to EPSG:3347 on import,
which is what makes `len_m` and every distance metres for every vintage.

## Invariants that span modules

These are the ones a change in one file can silently break in another. Each module's own header has
the reasoning; what follows is what must stay true.

- **Roxygen is the source of truth for `NAMESPACE` and `man/`.** `devtools::document()` overwrites
  both — never hand-edit either. Same for `vignettes/`: edit `vignettes.orig/` and precompute.
- **No test may require the internet.** Mock `cs_download` / `cs_url_is_available` instead. Network
  failure raises a classed `canstreet_network_error` so an offline session degrades rather than
  erroring opaquely (CRAN policy).
- **Never automate against Abacus's DMTI Spatial collection** — it is licence-restricted, and this
  package does not reference it anywhere.
- **Harmonization is alias-driven, never era-branched.** `schema_era` in the manifest is advisory;
  dispatch on the columns actually present. A column a vintage lacks becomes `NULL` throughout it,
  which is what keeps the union view legal.
- **`class` and `rank` are stored as labels, not codes.** `cs_class_categories()` is written in
  codes, because that is how the guides name them, so anything comparing against the stored column
  goes through `cs_class_label()` first. Change one without the other and `roads_only` silently
  keeps nothing. The `ENUM` is the whole published vocabulary, declared after every archive of a
  vintage rather than per archive, so `enum_range(NULL::typeof(class))` *is* the domain.
- **The road filter's sense is per product, not per size.** `cs_class_filter_sense()` says `keep`
  for the AMF and SNF and `drop` for every RNF, which decides what happens to an undocumented code.
  It is a semantic choice, not a way to shorten the emitted SQL.
- **Road/non-road assignments are read off the arcs, never across years.** The same word means three
  different things here (1996 `FTR`, 2001 `1306`, 2021 `26`), and the guide's own split cannot be
  inherited — see the `Z` case in `R/classes.R`.
- **One match predicate.** `cs_match_rules_sql()` serves both the residual test that builds the
  spine and the coverage test that tags it, and `cs_covered_by_sql()` ORs it over each newer
  vintage's own match table with its own tolerance. A merged pool would let a 2021-calibrated
  tolerance answer a 2006 question, and the `last_year == spine_vintage` invariant would break.
- **One folded name.** `cs_name_fold_sql()` is the single definition, called at staging and at
  tagging both.
- **`cs_schema_version()` and `cs_tnet_schema_version()` stay separate.** Bumping the first
  invalidates imported vintages and costs a ~7 GB re-download; the second invalidates only derived
  builds.
- **Geometry is stored untagged** in EPSG:3347, with the CRS in `canstreet_metadata` and reapplied
  on the way out, because DuckDB refuses an RTREE over a CRS-tagged column.

## Traps when writing new code against these files

Each is documented where it bites; this is the index.

- `ENCODING=ISO-8859-1` on every RNF shapefile read (`R/import.R`).
- Statistics Canada serves a missing release as a **soft 404** — 302 to a ~4 KB HTML page with
  `200 OK`. Probe content-type *and* length (`R/helpers.R`).
- A spatial filter must embed its geometry as a **WKT literal**, not a bound parameter; DuckDB's
  RTREE scan needs a constant. Verify with `EXPLAIN` (`R/api.R`).
- `ST_SetCRS` needs a constant, so a CRS cannot be a macro parameter (`R/db.R`).
- `always_xy = TRUE` on every transform, or a longitude of −123 is read as a latitude (`R/db.R`).
- A DuckDB `ENUM` cannot carry the same value twice, and three vocabularies give two codes one
  description (`cs_domain_disambiguate()` in `R/domains.R`).
- DuckDB spatial 1.5.4 has no `ST_Hausdorff`, `ST_Split`, `ST_Snap` or `ST_Relate`, and
  `generate_series` does not bind in a scalar position (`R/tnet.R`).
- A whole-arc `ST_Azimuth` is meaningless on a long arc — use `cs_local_az()` (`R/db.R`).
- Never mark AMF record bytes `latin1` and convert; never split the file on `0x0a` (`R/amf.R`).
- Never take the 2025 GeoPackage (CircularStrings), and 2001 is the one vintage where the `a`
  variant is the wrong one (`R/sources.R`).
- When folding names in a vignette, fold in DuckDB with `strip_accents`, not with R's
  `iconv(to = "ASCII//TRANSLIT")` — the latter writes `QUÉBEC` as `QU'EBEC` and manufactures
  differences the matcher never saw.

## Conventions

- 2-space indent, no tabs, UTF-8, trailing whitespace stripped (per `.Rproj`).
- `cache_path = canstreet_cache_path()` written literally in every exported signature; argument
  order identity → selection → behaviour (`refresh`, `quiet`) → `cache_path` last.
- User-facing functions return tibbles, or a lazy `dplyr::tbl()` that the caller collects
  explicitly.
- StatCan data is redistributed under the Statistics Canada Open Licence — cite it in `DESCRIPTION`
  and in the docs of any function that downloads data.

## Sibling packages as prior art

The author maintains a family of StatCan-data packages in `/Users/jens/R` — `canpumf` (whose
`robust_unzip()` and download wrapper this package adapts), `cansim`, `cancensus`, and `cangeocode`
(whose `R/geo_helpers.R` establishes the untagged-geometry + metadata-CRS pattern). Match their
established patterns rather than inventing new ones.

## Deliberately not done

Address-range agreement as a fourth matching signal (the columns are only ~55% populated, so it
could only break ties); node-level topology reconstruction; any assumption that `NGD_UID` is stable
across vintages — nothing documents that it is, and Statistics Canada states arc positions are "not
necessarily consistent with previous versions".
