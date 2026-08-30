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

Vignettes are **precomputed**: the sources live in `vignettes.orig/` (plain `.Rmd`, the whole
directory `.Rbuildignore`d), and `Rscript vignettes.orig/precompute.R` knits them into `vignettes/`,
which is what ships. Commit the resulting `.Rmd` and its `canstreet-*.png` figures. Name a subset
(`Rscript vignettes.orig/precompute.R canstreet-vancouver`) while iterating -- a full pass rebuilds
both temporal networks. The script refuses to run without a cache path set, because the vignettes
query real national files. Never edit `vignettes/*.Rmd` by hand; each one carries a generated-from
banner saying so.

## Architecture

Data flows manifest → download → harmonize → DuckDB → lazy `tbl`. One module per concern:

| File | Role |
|---|---|
| `R/sources.R` | **The manifest.** One row per vintage; every other module reads it. Adding a vintage is a data edit here, not a code change. |
| `R/download.R` | `canstreet_download()`, archive extraction |
| `R/abacus.R` | Dataverse manifest resolution and file access for the pre-2005 vintages |
| `R/amf.R` | The Area Master File reader: record layout, COMP-3, chains, `read_amf()` |
| `R/domains.R` | The published `class`/`rank` vocabularies, per vintage, and the `ENUM` retyping |
| `R/classes.R` | Which of those class values are road, per vintage: the category/status table and the filter predicate |
| `R/db.R` | Connection cache, spatial extension, storage CRS, metadata table, `segments` view |
| `R/import.R` | The harmonizer: target schema, alias resolution, address normalization |
| `R/api.R` | `get_road_network()`, `collect_road_network()`, `export_road_network()`, `canstreet_schema()` |
| `R/cache_path.R` | `CANSTREET_CACHE_PATH` → `canstreet.cache_path` option → `tempdir()` |
| `R/cache_mgmt.R` | `list_canstreet_cache()`, `remove_canstreet_cache()` |
| `R/tnet.R` | The cross-vintage matcher: calibration, spine cascade, interval cutting, emit |
| `R/tnet_api.R` | `build_temporal_network()` and the six other `*_temporal_network*()` functions |

**Sources.** Statistics Canada serves 2001 and 2005–2025 directly; 1976, 1981, 1991 and 1996 come
from the Abacus Data Network (UBC), whose Dataverse API needs no credentials for the
`statcan-public` collection. 1991 and 1996 are taken as the **ArcInfo interchange coverages**
(`net_*.zip` and `gsnf*r_e00.zip`), not as the shapefiles the same deposits derive from them — see
*The Abacus shapefiles are a bad conversion* below. 1976 (`hdl:11272.1/AB2/MESORS`) and 1981
(`hdl:11272.1/AB2/K0EZ55`) are British Columbia only — two flat files each, `bc.data` and `vancouver.data`, producer Statistics
Canada, licence NONE, no restricted files, so they are *not* the DMTI collection the prohibition
below covers.
The series' own history is set out in the 2006 Census Dictionary note on the road network file
(`census-recensement/2006/ref/dict/geo041a-eng.cfm`): area master files 1971–1991, street network
files 1996, road network files 2001 on; pre-2001 coverage is large urban centres only — under 1% of
the land area, ~35% of population in 1971, >50% 1981, 57% 1986, 62% in 1991 and 1996 — and the free
download begins with 2005. That page is the citable source for the coverage story the README tells.
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
- **The road-class filters translate.** `cs_class_categories()` is written in codes, because that is
  how the guides name them, so `cs_road_class_sql()` puts every list through `cs_class_label()`
  before emitting SQL. Change one without the other and `roads_only` silently keeps nothing.
  Comparing an `ENUM` column to a literal outside its vocabulary is legal in DuckDB — `IN` and
  `NOT IN` both just return no match rather than failing the cast — so a filter naming a code that
  vintage never uses is harmless.

**Every class carries a category and a status, and `roads_only` filters on both.** `R/classes.R`
gives each code in each vintage's vocabulary a feature `category` — `road` and eight non-road
families — and a build `status` (`operational`, `planned`, `under_construction`, `unknown`).
`cs_road_class_sql()` keeps `category == "road"` with an operational-or-unknown status; anything
else goes. Two things make it work:

- **The sense of the predicate is per product, not per size.** `cs_class_filter_sense()` returns
  `keep` for the AMF and SNF and `drop` for every RNF, which decides what happens to a code the
  guide never documented (import stores those bare). In a topographic base an unknown code is not
  assumed to be road; in a road network it is. Do not switch the sense to shorten the emitted SQL —
  it is a semantic choice, not a formatting one.
- **The assignments are read off the arcs, never across years.** The same word is three different
  features here: 1996's `FTR` "Trail" is the Bruce Trail and numbered park paths (`path`), 2001's
  `1306` "Trail: other" is the Klondike, Alaska and Dempster highways (`road`), and 2021's `26`
  "Reserve / Trail" is 92,393 km of forest service and resource road, 2,470 arcs typed `FSR` and
  5,103 `RD` (`road`). 2021's `27` "Rapid transit" is Ottawa's Transitway, a road carrying buses, so
  it stays too.

**`roads_only` is a status vector, not just a flag.** `cs_roads_only_statuses()` resolves `FALSE` to
no filter, `TRUE` to `cs_road_statuses()`, and a character vector to itself, validated against
`cs_class_statuses()`. It is called by `get_road_network()`, `export_road_network()` and
`cs_tnet_stage()`, so all three take the same argument. The point is that the category axis and the
status axis are wanted separately: **for geocoding, keep `"planned"`.** Nothing outside `category ==
"road"` carries an address worth having -- across all nine vintages, 448,000 non-road arcs yield 63
addressed ones and all 63 are artefacts (61 are 1981 AMF island and shoreline chains 14-16 km long
carrying a single stray address field and no street type) -- and walkways carry none at all: 1991
`FWA` 25 arcs, 1996 `FWA` 38 and `FTR` 1,469, zero addressed between them. But 177 of 2016's 194
`Planned` arcs *are* addressed block faces, over 97 distinct names, every one of which appears in
2021, so they were built. 2021's `Planned` is only 10 addressed of 203, and 2001's under-construction
1 of 360. Verified end to end: `roads_only = c("operational", "unknown", "planned")` gives 2016
2,163,058 arcs / 1,356,625 addressed against the default's 2,162,864 / 1,356,448, and 1996 529,055
arcs (the 85 `HPR`, none addressed) while still dropping the 100,519 non-road ones. A status vector
reaches `canstreet_builds` as a comma-joined string, since that table is EAV and holds one string per
key.

`canstreet_road_classes()` is that table exported, and `get_road_network(roads_only = TRUE)` applies
it — the argument the docs had long promised and did not have. Its default is `FALSE`, so direct
access still returns the file as it comes; `build_temporal_network()` still defaults to `TRUE`.

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
  `_` throughout 2001. Zero and negative address ranges are dominant, not edge cases. 2001's
  MapInfo release declares its address columns `Decimal(6, 0)` and simply stores 0 where there is no
  range, which lands on the zero sentinel `cs_normalize_address_ranges()` already clears, and the
  import runs warning-free. (The retired coverage was noisier: it declared the same columns integer
  but stored the string `NA`, so GDAL parsed those to **0** and warned once per field — `Value
  'NA    ' of field ARC.ADDR_TO_LEFT parsed incompletely to integer 0` — on top of ten
  `Normalized/laundered field name` warnings for the truncation the conversion needed. If you ever
  run `cs_coverage_to_shapefile()` again, only the latter are muffled.)
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
- **The 1991/1996 coverages declare no usable CRS**: 1991 reads back as untagged `GEOMETRY`, 1996 as
  `EPSG:4008`, which is the Clarke 1866 *ellipsoid*, not a datum. (The shapefiles the deposit derives
  from them carry an equally degenerate `GEOGCS["Unknown", DATUM["D_NAD_27_Canada", ...]]`.) Assign
  EPSG:4267 explicitly, as the manifest does.
- **1991 ships Lambert twins**, but only in its derived formats: `LSNF205` and `OT_HULL` duplicate
  `GSNF205` (Halifax) and `HULL_OTT` (Ottawa-Hull) as shapefiles, MapInfo tables and GeoJSON. The
  coverage set has 51 `net_*.zip` and no twins, so `file_pattern` alone keeps them out and
  `file_exclude` is `NA` — do not reintroduce a twin by widening that pattern.
- **2001 now comes from StatCan**, not Abacus, and the file to take is `grnf000r01m_e.zip` under the
  2011 `rnf-frr/files-fichiers/` path. The `…01g…`, `lrnf…01a…` and `…01a_f` spellings all return the
  soft-404 signature, as do the equivalent 1991 and 1996 paths — so only 2001 moves. The old Abacus
  route is no longer used.
- **2001 is the one vintage where the `a` variant is the wrong one.** The download page
  (`index-2011-eng.cfm?year=01`) offers four products, and its `Continue` button resolves each to a
  file: `grnf000r01a_e.zip` (388 MB, labelled ArcGIS but actually one 1.5 GB ArcInfo interchange
  coverage), `grnf000r01m_e.zip` (**244 MB, MapInfo — this is the one**), and `gsrn000r01a/m_e.zip`,
  the Skeletal Road Network File (27 MB / 9.7 MB), which is the four-level generalization, not the
  full network. The page is a POST form, so the URLs are not in the HTML; POST
  `lang=_e&type=<rnf000r01a|rnf000r01m|srn000r01a|srn000r01m>&year=11&getgeo=Continue` and read the
  redirect.
- **The MapInfo release is the same network with a better container.** `grnf000r02ml_e.MIF`/`.MID`
  (yes, `02` — released 2002) is the road network, `…02mp_e` the block polygons, both beside the
  reference-guide PDF. Verified identical to the coverage, row for row: 2,053,112 arcs, 1,736,503 km,
  the same class tally to the arc, 1,329,323 named, 458,813 with a left from-address, 51,847 accented
  names, and the same `roads_only` total — under the filter of the day, 1,880,960 arcs and
  1,329,336 km by one query run against both tables. What it wins on is mechanics — DuckDB's `ST_Read`
  scans the whole `.MIF` in **31 s** with no conversion step, where the coverage needs a 90-second
  `ogr2ogr` pass first (AVCE00 scans ~230 rows a second, over two hours for 2.05M arcs, and
  `cs_import_vintage()` opens the source twice). End to end the import is 62 s against roughly two
  minutes, on a 981 MB extraction rather than a 1.5 GB one plus a converted shapefile.
- **The MapInfo file declares its own charset**, `Charset "WindowsLatin1"` in the `.MIF` header, and
  the driver recodes on its own — no `ENCODING` guesswork. `cs_st_read_sql()` still passes
  `ENCODING=ISO-8859-1` unconditionally and that is harmless here: the MapInfo driver accepts the
  option, and the two encodings differ only over `0x80`–`0x9F`, of which the `.MID` holds not one
  byte (121,836 high bytes, every one `0xA0` or above — twice the coverage's 60,918, because `name`
  and `street` both carry them).
- **The MapInfo columns are richer than the coverage's, and none of the extras are mapped.** 25
  fields against the coverage's set: `arc_group` (`AD` road / `BO` boundary / `SB` sub-block / `NA`)
  cleanly separates the topology that `class` conflates, plus `street`, `addr_[ft][lr]_type`,
  `geo_source`, `ntd_source`, `al_source`, `ar_source` and `length_km`. The road filter still works
  off `class` and still gave exactly the same length on both tables, so there is no reason to add
  `arc_group` to the target schema — but it is the cleaner predicate if that ever changes.
- **The address columns are spelled in full** — `addr_fm_left`, and note `addr_fm_rght`, not
  `_right`. A MapInfo column name is not clipped to ten characters the way a `.dbf` field is, so
  unlike the converted coverage these reach the harmonizer untruncated; `cs_target_schema()` carries
  both spellings. The identifier is `arc_id` (not `RB_UID`, as the Abacus deposit had), unique across
  all 2,053,112 rows, and there is `rank1`–`rank4` rather than a plain `rank` — those are the four
  skeletal levels of detail, per the download page's own description of the Skeletal file — so `rank`
  stays NULL for 2001.
- **A coverage is read directly, and staged first.** `cs_resolve_line_source()` hands a `.e00` to
  `cs_e00_stage()`, which writes one repaired copy under `canstreet_staged/` keeping the original
  filename — so `source_file` records `NET_TORO.E00`, a file the deposit actually contains — and
  `cs_st_read_sql()` then adds `layer = 'ARC'`, because a coverage names its layers after their
  geometry (`ARC` the network, `PAL`/`CNT`/`LAB` the polygon side) and `ST_Read` would otherwise take
  whichever comes first. There is no `ogr2ogr` conversion step any more: DuckDB reads the 51 1991
  coverages in 143 s, and a whole vintage imports in about four minutes. (The old converter existed
  because 2001's 1.5 GB ArcGIS coverage scanned at ~230 arcs a second; these are two orders of
  magnitude smaller and 2001 comes from StatCan in MapInfo now.)
- **GDAL opens the first volume of a multi-volume coverage and says nothing.** 1991 ships its larger
  units as `NET_TORO.E00` beside `.E01` … `.E11`, and `ogrinfo` on the `.E00` alone reports 27,327 of
  Toronto's 82,725 arcs with a matching extent — a plausible number, no warning. The split is by byte
  count, so `cs_e00_stage()` concatenates the volumes in extension order. Volume count does not
  predict it: Calgary (4 volumes) and Québec (5) read whole without being joined, six other units do
  not, so always join.
- **AVCE00 has no open options at all**, so no `ENCODING` reaches the driver and a byte above 0x7F
  arrives in DuckDB as an invalid UTF-8 string. It cannot be recoded either: the interchange format
  is ASCII text in fixed-width fields, so widening one byte to two shifts every field after it on
  that line. `cs_e00_ascii` folds the Latin-1 supplement to one ASCII byte each instead. Across the
  whole 1991 and 1996 corpus exactly one byte is affected — the `0xA0` in Toronto's `EA\xa096`, an
  enumeration-area label, which becomes the ordinary space it stands for.
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
  classed value that is). `cs_categories_amf()` keeps those three plus the unclassed, which is
  6,574.6 of 1976's 8,857 km and 10,497.3 of 1981's 15,508 km — the same ~2/3 the SNF filter keeps.
- **AMF node-pair segments are block faces.** Median length 102 m, and the four address fields at a
  node are, in order, to-left, to-right, from-left, from-right, so a face takes `from` from the node
  it starts at and `to` from the node it ends at. Verified on Main Street in Vancouver, where
  Alexander to Powell resolves to 100–198 and 101–199, and in bulk: of the fully addressed faces,
  100% have the same parity at both ends of a side, 100% have opposite parity across the street, and
  96% span under 200 civic numbers.
- **The AMF geometry is not the weak link the age suggests.** Calibrated against 2021
  over the Vancouver CMA, `recall_p50` is 11.5 m for 1976 and 11.0 m for 1981 -- *lower*
  than 1991's and 1996's 15.7 m, and on a par with 2001 (11.2) and 2006 (11.6). Their
  tolerances land at 37 and 34 m, inside the [10, 40] clamp rather than pinned to it. What
  improves after 2006 is vertex density, not registration; 2011 and 2016 clamp to the 10 m
  floor because they share 2021's base geometry.
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
- **What the road filter costs each vintage**, run against the cached national tables: 1976 keeps
  45,999 arcs / 6,575 km of 60,883 / 8,857; 1981 75,220 / 10,497 of 103,774 / 15,508; 1991 503,469 /
  104,296 of 599,625 / 160,778; 1996 528,970 / 109,182 of 629,574 / 167,238; 2001 1,880,600 /
  1,328,881 of 2,053,112 / 1,736,503; 2006 and 2011 lose nothing; 2016 loses 194 arcs / 30.1 km and
  2021 203 / 27.3. The last two are the whole of `28` Planned, which 2011 does not use at all.
- **Only three vintages carry a class that says a road was not built yet**, and all three are small:
  1996's `HPR` "Highway proposed" is 85 arcs / 53.3 km (Highway 403, Highway 407, Autoroute 50 —
  none of them open in 1996; `HUC` occurs in neither SNF vintage), 2001's eight "under construction"
  descriptions are 360 arcs / 455.5 km, and `28` Planned is ~200 named subdivision streets in each
  of 2016 and 2021. Small, but they are exactly the arcs that would date a road to the vintage that
  anticipated it, so `roads_only` drops them.
- **The Street Network File records unbuilt roads a second way, and that one is not filtered.** The
  fixed-width `NAME` field packs `PROP.`/`PROJ.` as a suffix on 2,182 arcs / 470 km in 1991 and 932 /
  260 km in 1996 — an order of magnitude more than `HPR` — and those arcs are classed as ordinary
  highways. Deliberately left alone: it is a name-parsing question, not a class one.
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
  1,736,503 km as read, 1,328,881 km once the non-road classes above and the 360 under-construction
  arcs are dropped (1,329,337 km with the under-construction arcs left in).
- **1991's class vocabulary is a strict subset of 1996's**, so the SNF road set — calibrated on
  1996 — needs no extension for it: nothing appears in 1991 that 1996 lacks, and 1996 adds only `GJA`,
  `GCO`, `U`, `GCH`. 1991 imports 160,778 km, of which `roads_only` keeps 503,469 arcs / 104,296 km
  and drops 96,156 arcs / 56,482 km — the same ~35% as 1996, and verifiably not road: `RSI`/`RMU`/`RSG`
  are the CNR and CPR mains and yards, `Z` is literally named `POWER LINE 001`, `W` watercourse (10,766
  km), `CEA` the census EA boundary. Its geometry checks out too: 93% of ordinary-street midpoints lie
  within 40 m of a 2021 arc, and the national extent is lon −124.5…−52.7, lat 42.1…54.0.
- **The Abacus shapefiles are a bad conversion, which is why the manifest takes the coverages.**
  Both 1991 and 1996 deposit the ArcInfo interchange coverages *and* shapefiles derived from them,
  and for 1991 the derivation is broken. Four units — Halifax (`GSNF205`), Chicoutimi-Jonquière,
  Montréal and Toronto — ship no `ARC_ID` column at all, and in them every field after a street name
  containing a comma is shifted one position, because the conversion went through a CSV step that
  never quoted: 13,593 arcs / 2,309 km carry a `class` that is really the tail of a name, and 2,344
  more have had an apostrophe deleted outright. `HULL_OTT` merged `CLASS` and `TYPE` into one column
  and blanked 345 `Z…` names. 1996's shapefiles are faithful field for field — it was switched over
  as a matter of principle, not to fix anything. Reading the coverages directly costs nothing and
  fixes all of it: the arc counts and total length are unchanged (599,625 / 160,778 km and
  629,574 / 167,238 km), every arc now carries an identifier, and `roads_only` gains exactly the five
  arcs the audit predicted.
- **`arc_id` is unique only within a source file.** The SNF ships one coverage per urban area and
  numbers each from scratch: 1991's 599,625 arcs all carry an identifier but only 599,038 distinct
  values, 1996's 629,574 only 628,124. `(source_file, source_id)` is unique in both. Never join an
  SNF vintage on `source_id` alone. (Before the switch to the coverages, four 1991 units had no
  identifier column at all, so only 414,771 arcs carried one — that is fixed, not a different fact.)
- **The SNF is unaccented ASCII** — not one non-ASCII character survives in either vintage's `name`,
  and the single high byte in the source files is the non-breaking space `cs_e00_ascii` folds — so
  the Latin-1 problem is an RNF matter only, never an SNF one.
- **The SNF `NAME` field is fixed-width and packs a status suffix**, which survives `trim()` as a run
  of interior spaces: `CLAIRVIEW      PROP.` (proposed), `DESAUTELS     PROJ.` (projected, i.e. not
  built in that year), `CAMBRIAN      PRIV.` (private), plus French article and qualifier tokens (`DU`,
  `FR`, `VI`, `LR`, `VP`, `FA`) and bare direction letters. `TYPE` and `DIRECTION` are separate and
  populated independently, so this is not a mis-parse — `J.A. PARE     PROJ.` carries `TYPE = BV`. It
  affects 13,340 of 1991's 580,020 named arcs (2.3%) and 1,399 of 1996's 609,009 (0.2%). Two
  consequences: the packed names never match a modern `name_fold`, and ~2,000 `PROP.`/`PROJ.` arcs
  are roads that did not exist in the year that carries them.
- **The 1991/1996 SNF is a full topographic base, not a road network.** `class IS NULL` is an ordinary
  street (502,150 arcs in 1996, of which 96% are typed and 76% addressed); a non-null `class` names a
  *feature type*, of which only eleven are roads — see `cs_categories_snf()`. Watercourses, rail,
  hydro lines, EA boundaries and the outlines of parks, golf courses and airports account for 58,003
  of the 1996 file's 167,238 km (1991: 56,482 of 160,778). Leaving them in reports every river as a
  retired road: the Calgary pilot's implausible "retired 1996 road" fell from 56.6 km to 2.60 km once
  they were filtered. Bridge arcs were checked and do *not* duplicate the street underneath.
- **2001's line layer carries the census boundary topology too**, which is that vintage's equivalent
  of the SNF problem — and the 2006 Census Dictionary note confirms it was deliberate: "For 2001, the
  road network files contained both road and boundary arcs". Its `class` is mostly a numeric feature code (1011 is the ordinary street, 688,063
  arcs; 1003/1015/1016/1020/1022/1306 are the highway families) but three codes are not road:
  **`BO`** (167,916 arcs, **388,345 km**), **`1536`** (1,625 arcs, 18,650 km) and **`SB`** (2,611
  arcs, 171 km). None of the three has a single named, typed or addressed arc; `1536`'s longest arcs
  run along 141°W and across 85–87°N — the Yukon–Alaska meridian and the Arctic Ocean limit — and in
  Calgary only 60 of 1,057 `BO` arcs come within 10 m of a road, so they are separate geometry, not
  block boundaries laid along street centrelines. Dropping the three leaves **1,329,337 km** against
  2006's 1,326,099 km, 0.24% apart: the whole surplus was topology. `cs_categories_rnf_2001()` names
  them, and `cs_road_class_sql()` inverts the predicate for every RNF vintage — it says what to
  *drop*, where the SNF and AMF branches say what to keep, because in a Road Network File everything
  the guide does not explain is still road. `1307` (346 arcs,
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

**The crosswalk carries each source arc's own name and file** — `src_name` and `source_file`, added
at `tnet_schema_version` 2, which invalidates any build written before it. Both are identity, not
decoration: `source_id` is unique only within one file for the AMF and SNF vintages, so joining a
crosswalk row back to its vintage table on `source_id` alone fans out (measured on the Vancouver
build: 1976 48,695 rows → 48,813, 1996 69,912 → 70,329, with some segments picking up two different
names). `src_name` is prefixed rather than named `name` because the intended use is a join against
the main table, whose `name` is the spine vintage's.

**A rename is `match_kind = 'geometry'`** — the arcs agree on position and bearing while the folded
names do not. Vancouver's pool runs 10,548 such pairs for 1976 down to 587 for 2016, and it is not
all renames: roughly half of 2001's 8,868 have a blank name on one side, which is a road that gained
a name rather than one that changed it. What is left mixes real renames (`South Ridge` →
`Southridge`), StatCan's own typo fixes (`Rennie` → `Rannie`, `Ione Island Causeway` → `Iona Island
Causeway`) and naming-convention changes (`Fraser Delta Thruway` → `99`, `Tenth` → `10th`), so any
rename product has to classify, not just diff. Note the blind spot: rule B joins on exact folded-name
equality and so **cannot match across a rename by construction**, which means a road that was both
renamed and coarsely digitized reads as a retirement plus a new road, not a rename.

`vignettes.orig/canstreet-renames.Rmd` is the classification worked end to end, scoped to the
**City of Vancouver CSD** (built over the CMA for the halo, read over the city polygon — an attribute
filter would drop the pre-2011 vintages, which carry no region columns). Its funnel is the measured
shape of the problem: 16,096 raw name changes -> 3,239 after the matcher's own fold (case, accents,
the numeric ordinal) -> 2,930 with both sides named -> *loosely matched* 1,795 segments / 143 km
(either side matched at 10 m or more), *street type moved between fields* 288 / 30.1 km, *spelling
convention* 149 / 13.8 km, leaving 698 / 64.2 km of candidate rename. Of that, 80 of 265 name pairs
reverse — 1996 alone using `NORTH KENT`/`SOUTH KENT` where its neighbours write `KENT`, and the files
disagreeing where one named structure ends (`ANDERSON` <-> `GRANVILLE`) — leaving 183 pairs / 44.7 km
that read as real, headed by Kent Avenue splitting into `E KENT`/`W KENT` in 2016 (105 segments in one
window), `CONNAUGHT BRIDGE` -> `CAMBIE BRIDGE`, and the Stanley Park and Coal Harbour roads. Over the
whole CMA the same pipeline runs 88,100 -> 30,183 -> 1,543 pairs / 448 km, whose largest single event
is Highway 17 moving to the South Fraser Perimeter Road between 2011 and 2016. Two things in that
pipeline are load-bearing rather than cosmetic: the fold
is computed in DuckDB with `strip_accents` and the same `regexp_replace` the matcher uses, because R's
`iconv(to = "ASCII//TRANSLIT")` writes `QUÉBEC` as `QU'EBEC` and would manufacture differences; and
the "street type moved" class is *proven* by joining the crosswalk back to the vintage table on
`(source_file, source_id)` — 1981 files `LOUGHEED HIGHWAY` with `type` empty, 2001 files `Lougheed`
with `type = HWY`, and 1991 files `GRANDVIEW HIGHWAY` with `type = HY` where 1996 files `GRANDVIEW`
with the same `HY` — which is exactly the join the schema-2 crosswalk columns exist to make possible.
There is no `temporal_network_renames()` accessor: the classification is judgement about a particular
region's naming conventions, not something the package should assert.

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

**Nine vintages over the Vancouver CMA build in about a minute** (85,044 segments, 11,365 km;
1976 6,494 km -> 1981 7,069 -> 1991 9,317 -> 1996 9,472 -> 2001 9,955 -> 2006 10,079 ->
2011 10,220 -> 2016 10,380 -> 2021 10,493 -- strictly monotone, 643 superseded pieces
dropped). `first_year` is dominated by coverage, not construction: 1991 alone adds 2,421 km
CMA-wide, which is the Street Network File reaching past the 1981 urban envelope into the
Fraser Valley, not a year Vancouver built 2,421 km of road. Inside the City of Vancouver
CSD, where coverage was complete in 1976, 93% of length has `first_year == 1976` against
57% CMA-wide. That contrast is what `vignettes.orig/canstreet-vancouver.Rmd` is built
around, and it is why that vignette subsets the city with a *polygon*: `csduid_l` on a
tnet row comes from the spine vintage, and every vintage before 2011 carries none, so an
attribute filter would drop exactly the oldest segments.

**The folded name normalizes a numeric ordinal, and it has to.** `name_fold` is the key rule B
joins on, and the files respell the numbered street at 2001: every pre-2001 vintage writes Vancouver's
avenue as `15`, every vintage from 2001 on writes `15th`. Inside the Vancouver CMA the AMF and SNF
vintages carry *zero* ordinal-suffixed arcs against 2001's 4,511 and 2021's 5,043, so a bare fold
switched the name rescue off across exactly that boundary. It matters because rule A cannot cover for
it there: the pre-2001 lineage puts 15th Avenue about 40--48 m north of where 2001 onward puts it
(1976/1981 49.25862, 1991/1996 49.25874, 2001/2006 49.25832, 2011/2021 49.25819 at Maple), a real
disagreement wider than 1976's calibrated 37 m tolerance, so rule A correctly declines and rule B is
the whole safety net. Without the normalization one road was emitted twice --- in one Kitsilano box,
144 segments / 21.69 km dated `first_year` 2001 and named `15th`...`27th`, beside 145 segments /
21.44 km retiring after 1996 and named `15`...`27`. `cs_name_fold_sql()` is the single definition,
called at both the staging and the tagging site; it strips the suffix only after a leading run of
digits, so `1st Avenue`, `15th Line` and `St Clair` are untouched. Measured before committing: it
creates **zero** new name collisions in either region, and it recovers 246 segments / 33.19 km
CMA-wide that were retiring as phantoms. Calgary, whose earliest vintage is 1996 and which barely
numbers its streets, moved by one segment / 0.2 km --- which is the control.

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
