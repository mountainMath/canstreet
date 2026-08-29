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
| `R/amf.R` | The Area Master File reader: record layout, COMP-3, chains, `read_amf()` |
| `R/domains.R` | The published `class`/`rank` vocabularies, per vintage, and the `ENUM` retyping |
| `R/db.R` | Connection cache, spatial extension, storage CRS, metadata table, `segments` view |
| `R/import.R` | The harmonizer: target schema, alias resolution, address normalization |
| `R/api.R` | `get_road_network()`, `collect_road_network()`, `export_road_network()`, `canstreet_schema()` |
| `R/cache_path.R` | `CANSTREET_CACHE_PATH` → `canstreet.cache_path` option → `tempdir()` |
| `R/cache_mgmt.R` | `list_canstreet_cache()`, `remove_canstreet_cache()` |
| `R/tnet.R` | The cross-vintage matcher: calibration, spine cascade, interval cutting, emit |
| `R/tnet_api.R` | `build_temporal_network()` and the six other `*_temporal_network*()` functions |

**Sources.** Statistics Canada serves 2001 and 2005–2025 directly; 1976, 1981, 1991 and 1996 come
from the Abacus Data Network (UBC), whose Dataverse API needs no credentials for the
`statcan-public` collection. 1976 (`hdl:11272.1/AB2/MESORS`) and 1981 (`hdl:11272.1/AB2/K0EZ55`) are
British Columbia only — two flat files each, `bc.data` and `vancouver.data`, producer Statistics
Canada, licence NONE, no restricted files, so they are *not* the DMTI collection the prohibition
below covers.
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

**`class` and `rank` are stored as labels, not codes.** `R/domains.R` carries the
published vocabulary for each vintage and `cs_label_vintage()` retypes both columns as a DuckDB
`ENUM` of labels at the end of `cs_import_vintage()`. Three things make this work:

- **After every archive, never per archive.** The `ENUM` is declared over the values the finished
  table holds, and an SNF vintage arrives as 51 shapefiles into one table.
- **The type is the whole vocabulary**, not just the codes observed, so
  `enum_range(NULL::typeof(class))` *is* the domain. Any code observed but not published is appended
  and stored bare — a vintage never loses a value because the guide does not explain it.
- **The road-class filters translate.** `cs_snf_road_classes()` and friends are written in codes,
  because that is how the guides name them, so `cs_road_class_sql()` puts every list through
  `cs_class_label()` before emitting SQL. Change one without the other and `roads_only` silently
  keeps nothing.
  Comparing an `ENUM` column to a literal outside its vocabulary is legal in DuckDB — `IN` and
  `NOT IN` both just return no match rather than failing the cast — so a filter naming a code that
  vintage never uses is harmless.

`cs_tnet_stage()` casts both columns back to `VARCHAR` as it stages, because a build unions arcs
from several vintages and their `ENUM`s are not the same type — so a `tnet_*` table carries labels
as plain strings. The `segments` view needs no help: `UNION ALL BY NAME` resolves `ENUM` against
`VARCHAR` to `VARCHAR` on its own, and `export_road_network()` needs none either — DuckDB writes an
`ENUM` to Parquet as its labels in a `VARCHAR` column.

**The AMF does not go through the harmonizer's alias table**, because it is not a GIS file and has
no columns to alias. `cs_import_vintage()` branches on `archive == "none"`, and
`cs_import_amf_file()` registers the parsed segments as a DuckDB view and inserts them with an
explicit column map, one INSERT per UTM zone (`ST_SetCRS` needs a constant). Everything downstream
of the table is identical.

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
- **The Area Master File is a mainframe flat file and no driver reads it**, so `R/amf.R` parses it.
  113-byte records in 1976, 95 in 1981 — the difference is exactly the 18 bytes six coordinate pairs
  save when packed two digits to the byte (113 − 6 − 12 = 95). Records are stored with trailing
  blanks stripped.
- **1981 is EBCDIC and the deposit ships it decoded through code page 037**, so its packed
  coordinates survive as Latin-1 mojibake. Re-encoding each character back to cp037 restores the
  original byte (cp037 is a bijection on 0–255), then COMP-3 unpacks it. A blank field is four
  EBCDIC `0x40`s, whose sign nibble 0 is what makes it decode to `NA`; in 1976 the same blanks are
  *printed*, so its sentinel is the literal string `4040404`.
- **Never mark AMF record bytes `latin1` and convert.** R converts through CP1252, where `0x81`,
  `0x8d`, `0x8f`, `0x90` and `0x9d` are undefined and come back as a multi-character escape, so the
  string stops being one character per byte and every column-addressed field after the packed
  coordinate shifts. It hit 18% of the 1981 records and only showed up as a wrong cross-street name
  on those rows. `cs_amf_nodes()` blanks everything outside printable ASCII in the *text* view
  instead and reads coordinates from the raw matrix.
- **A packed coordinate byte can be a newline**: EBCDIC `0x25` decodes to LF and its nibbles 2 and 5
  are an ordinary digit pair, so splitting on `0x0a` tears records apart. `cs_amf_record_bounds()`
  rejoins any fragment that does not open with four ASCII digits — provable, not heuristic, since
  only EBCDIC `0xF0`–`0xF9` decode to a digit and their high nibble 15 is not one.
- **Detect the AMF layout on width *and* the coordinate columns.** Detecting on a high byte misreads
  1976, whose last feature header carries trailing rubbish; detecting on width alone misreads a file
  whose trailing cross-street fields happen to be blank throughout, because trailing blanks are
  stripped. `cs_amf_coords_are_text()` settles it: 1976 writes columns 32–45 as fourteen ASCII
  digits and packed data cannot.
- **AMF records are not in sequence order in the file.** 19,645 of the 45,933 node records in
  1981's `bc.data` step backwards, with a chain's `E` filed before its `B`; left alone that shatters
  6,834 chains into 22,175 and loses 40% of the segments. `cs_amf_nodes()` sorts on
  `(sheet, cma, area, feature, seq_no)` — the sequence numbers are spaced in tens precisely so
  records can be inserted, so sorting is the file's own intent, not a repair.
- **An AMF feature number is unique only within a map sheet**, the same trap 1991's `arc_id` sets.
  The sheet is part of `source_id`, and even then 22 collisions remain in 1981's `bc.data`, whose
  six Victoria sheet headers are filed together ahead of their data rather than each ahead of its
  own. `(source_file, source_id)` is the key.
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
- **The reference guide ships inside the archive.** Every RNF zip carries its own
  `92-500-G<year>001-eng.pdf` (2001: `92f0157g2001000-eng.pdf`), and the 1991 Abacus deposit carries
  `snfarc.pdf` and `snfamf.pdf`. Those are where the class and rank vocabularies come from, and they
  are the *only* place for 2011 and 2016 — the StatCan attribute-domain pages exist for 2021 only,
  and `index2011-eng.cfm?...id=CLASS` and the 2016 spelling both return the 4,099-byte soft-404.
  Extract the PDF from the cached zip and `pdftotext -layout` it rather than searching the web.
- **A DuckDB `ENUM` cannot carry the same value twice**, and three vocabularies give two codes one
  description: 2016 defines `90` and `95` both as Unknown, 2001 has `0` and `U` both Unknown and `92`
  and `94` both a truncated "Bridge :", and the SNF's List A names both `WAQ` and `SAQ` Aqueduct.
  `cs_domain_disambiguate()` appends the code to *every* member of a colliding group rather than
  inventing a distinction the source does not make.
- **`normalizePath()` leaves a non-existent leaf alone**, so keying a cache on a database file path
  gives one key before the file exists and another after (macOS `/var` → `/private/var`). `cs_conn_key()`
  keys on the resolved *directory*.

## Verified data facts

Established by reading the actual files, not the documentation. Trust these over the reference guides.

- **The AMF class vocabulary is a feature type, as the SNF's is**, and blank is the ordinary street
  (146,693 of 194,000 node records, 95% typed, 41% addressed). Read off the four deposits: `SN`
  shoreline, `WN` watercourse, `MB` municipal boundary, `RN` railway, `GB` park/reserve/institution
  outline, `IN` island, `PP` park or school property, `UB` urban/rural boundary, `OB`/`CB` other
  boundary — none of them road. `HN` is the highway (Trans-Canada, Gaglardi Way, interchanges), `BN`
  the bridge or tunnel, and `Z` an arterial (Kingsway, Lougheed Highway; 63% addressed, the only
  classed value that is). `cs_amf_road_classes()` keeps those three plus the unclassed, which is
  6,574.6 of 1976's 8,857 km and 10,497.3 of 1981's 15,508 km — the same ~2/3 the SNF filter keeps.
- **AMF node-pair segments are block faces.** Median length 102 m, and the four address fields at a
  node are, in order, to-left, to-right, from-left, from-right, so a face takes `from` from the node
  it starts at and `to` from the node it ends at. Verified on Main Street in Vancouver, where
  Alexander to Powell resolves to 100–198 and 101–199, and in bulk: of the fully addressed faces,
  100% have the same parity at both ends of a side, 100% have opposite parity across the street, and
  96% span under 200 civic numbers.
- **The AMF datum is NAD27, verified rather than assumed.** The zone is stated per map sheet
  (`cs_amf_zone_crs()` = `26700 + zone`), and a file spans zones. The 1976 node at Main and Hastings
  (492833, 5458561) lands within 13 m of the intersection through EPSG:26710 and 200 m away through
  EPSG:26910. In bulk, 89–92% of AMF road length has a 1991 SNF arc within 20 m of its midpoint and
  95–96% within 40 m; against 2021 it is 68–73% and 88–91%, the gap being 2021's finer digitization.
- **The class vocabularies are per-vintage and read from primary sources.** 1991/1996 use List A of
  the Street Network File User Guide (`snfarc.pdf` in the Abacus deposit), which confirms from the
  documentation what was already established from the data: a blank `class` is its own row,
  "Addressable Single street & public access lane", so the ordinary street really is the unclassed
  value, and `Z` really is "Other features" — hydroline, telephone line, fence, pipeline. 2001 uses
  the numeric composite vocabulary in section 5 of `92f0157g2001000-eng.pdf`, where `1011` is
  "Road: n/a, street, n/a, n/a, operational, hard", `1536` is **Neatline** and `BO`/`SB` are
  **Boundary arc** / **Sub-Block boundary arc** — which is the documentary confirmation that
  dropping those three drops topology. 2011 onward share one vocabulary that is nonetheless revised
  twice: **2016 defines `95` as a second Unknown** ("90, 95 — Unknown" in its guide, the only place
  that code is documented anywhere), and 2021 retires `95` and adds `87` Winter.
- **Do not reuse List A for the Area Master Files.** The 1991 guide's AMF-format variant
  (`snfamf.pdf`) decomposes the class into (feature type, sub-type, street type), which explains most
  of the 1976/1981 two-character codes as type + sub-type — `HN` highway, `WN` watercourse, `SN`
  shoreline, `RN` railway, `BN` bridge, `MB`/`CB`/`GB`/`UB` the boundary families, `PP` property. But
  it makes `IN` "Falls/Dam/other associated" where the data reads as island, and `Z` "hydroline,
  telephone, fence, pipeline" where the AMF's `Z` arcs are Kingsway and Lougheed Highway and 63%
  addressed. The 1976/1981 vocabulary is an earlier revision, no guide for it survives in any
  deposit, so `cs_class_domain()` returns `NULL` for them and the codes are stored as they are.
- Segment counts and length: 1976 = 60,883 / 8,857 km, 1981 = 103,774 / 15,508 km, both BC urban
  only. All named; 1976 has 43,357 typed and 24,620 addressed, 1981 has 75,351 and 35,321.
- **Identifier spellings**: `arc_id` (1991/1996), `RB_UID` (2001–2010), `NGD_ID` (2005), `NGD_UID`
  (2011+), `NGDUID` (2016/2017 — no underscore).
- **2021 has no `CMAUID` columns**; 2011 and 2016 do. An empty `cmauid_l` for 2021 is correct.
- **2006 carries more total length than 2021** (1.33M vs 1.17M km) because it holds far more very long
  arcs — 22,486 over 5 km against 2021's 13,055. Not an import bug; neither table has a duplicate
  geometry.
- Segment counts: 1991 = 599,625 and 1996 = 629,574 (both urban only); 2001 = 2,053,112;
  2006 = 1,869,564; 2011 = 1,973,932; 2016 = 2,163,058; 2021 = 2,242,117.
- 1991 and 1996 cover **urban areas only**; 2001 onward is national. 2001 imports 2,053,112 arcs /
  1,736,503 km as read, 1,329,337 km once the non-road classes above are dropped.
- **1991's class vocabulary is a strict subset of 1996's**, so `cs_snf_road_classes()` — calibrated on
  1996 — needs no extension for it: nothing appears in 1991 that 1996 lacks, and 1996 adds only `GJA`,
  `GCO`, `U`, `GCH`. 1991 imports 160,778 km, of which `roads_only` keeps 503,464 arcs / 104,294 km
  and drops 96,161 arcs / 56,485 km — the same ~35% as 1996, and verifiably not road: `RSI`/`RMU`/`RSG`
  are the CNR and CPR mains and yards, `Z` is literally named `POWER LINE 001`, `W` watercourse (10,766
  km), `CEA` the census EA boundary. Its geometry checks out too: 93% of ordinary-street midpoints lie
  within 40 m of a 2021 arc, and the national extent is lon −124.5…−52.7, lat 42.1…54.0.
- **`arc_id` is unique only within a source file for 1991.** 599,625 arcs carry 414,771 identifiers but
  only 414,367 distinct values, because the SNF ships one shapefile per urban area and numbers each
  from scratch; `(source_file, source_id)` is unique. 1996 happens not to collide. Never join an SNF
  vintage on `source_id` alone.
- **The SNF is unaccented ASCII** — 0 accented names in 1991, exactly 1 in 1996 — so the Latin-1 `.dbf`
  problem is an RNF and 2001-coverage matter only, never an SNF one.
- **The SNF `NAME` field is fixed-width and packs a status suffix**, which survives `trim()` as a run
  of interior spaces: `CLAIRVIEW      PROP.` (proposed), `DESAUTELS     PROJ.` (projected, i.e. not
  built in that year), `CAMBRIAN      PRIV.` (private), plus French article and qualifier tokens (`DU`,
  `FR`, `VI`, `LR`, `VP`, `FA`) and bare direction letters. `TYPE` and `DIRECTION` are separate and
  populated independently, so this is not a mis-parse — `J.A. PARE     PROJ.` carries `TYPE = BV`. It
  affects 11,180 of 1991's 579,675 named arcs (1.9%) and 1,399 of 1996's (0.2%). Two consequences: the
  packed names never match a modern `name_fold`, and ~2,000 `PROP.`/`PROJ.` arcs are roads that did not
  exist in the year that carries them.
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
(163 pieces / 4.3 km for Calgary) and the count is recorded on the build. Without it, 9 of 3,744 rows
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
→ 2021 11,505, and the 1996→2001 jump is coverage, not construction). Adding 1991 costs nothing:
all seven vintages over the Calgary CSD envelope build in 19 s (65,631 segments, 8,143 km; 1991
4,427 km → 1996 4,870 → 2001 5,930 → 2006 6,567 → 2011 6,919 → 2016 7,422 → 2021 7,727 — strictly
monotone, and the invariant holds on every row), with 1991 calibrating to a 35 m tolerance.
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
