# Corpus facts

Numbers established by reading the actual files, not the reference guides. Trust these over the
documentation, and over any recollection of it. Kept here rather than in `CLAUDE.md` because they
are a lookup table, not a rule; the *reasoning* each one supports lives in the module that acts on
it (`R/classes.R`, `R/domains.R`, `R/amf.R`, `R/tnet.R`).

## Provenance, and what does not exist

| Vintage | Handle / host | Note |
|---|---|---|
| 1971, 1976, 1981, 1986 | MountainMath S3, `canstreet/amf_<year>.zip` | National. The files Statistics Canada delivered on request, one zip per census |
| 1991 | `hdl:11272.1/AB2/2FCGQJ` (Abacus) | 51 `net_*.zip` coverages |
| 1996 | `hdl:11272.1/AB2/WFFBPW` (Abacus) | 50 `gsnf*r_e00.zip` coverages |
| 2001 | Statistics Canada, 2011 `rnf-frr/files-fichiers/` path | `grnf000r01m_e.zip`, MapInfo |
| 2005-2025 | Statistics Canada | 92-500-X |

**The hosted Area Master File archives.** Statistics Canada never served these online; the national
set arrived on request, 462 flat files in the 119-byte `wide` transcription (`R/amf.R`), and is
re-zipped one archive per census with the files untouched under their own names and the documents
that came with them in `documentation/` (record layouts, the 1971 and 1976 reference lists, the
record counts, and the January 1988 *Area Master File User Guide* in every archive, plus a
`README.txt`).

| Archive | Bytes | Files | sha256 |
|---|---|---|---|
| `amf_1971.zip` | 10,152,661 | 34 | `536c86069b572e2ecc7b0cc5ba4ee6777c1c7bcd300ae93b6937da3d6c80ed86` |
| `amf_1976.zip` | 17,399,480 | 99 | `7d0a42082bfd9d9d22302d7f8d09e736d449a40684abec86720cf57e7634f71f` |
| `amf_1981.zip` | 19,715,880 | 135 | `d8bb0a74ea7e1e4668527a6fe016aa86d8691c44bee11ef6ae01b681dfb22376` |
| `amf_1986.zip` | 27,710,295 | 194 | `908f548fbba13d9e253b026fdf6b9e3df148e9eb07eb5b705cb1660141737a8c` |

**The Abacus British Columbia extracts are retired, not lost.** `hdl:11272.1/AB2/MESORS` (1976,
`bc.data` and `vancouver.data`, the 113-byte `text` transcription) and `hdl:11272.1/AB2/K0EZ55`
(1981, the 95-byte EBCDIC `packed` original) were the manifest's 1976 and 1981 until the national
files were to hand. Both list Statistics Canada as producer, licence NONE and no restricted files,
so they are not the licence-restricted DMTI Spatial collection on the same host -- which this
package deliberately never touches (`R/abacus.R`). `read_amf()` still opens both. They are not the
national files' BC subset arc for arc: Abacus 1976 is 60,883 segments / 8,857 km in 2 files against
67,146 / 9,512 km in the 15 national BC files, and Abacus 1981 103,774 / 15,508 km against 106,093 /
15,144 km in 29.

**The same delivery's 1991 and 1996 folders add nothing.** Its 51 `NET_*.zip` for 1991 hold the same
111 members as the Abacus deposit, byte for byte (CRC and size). Its 1996 folder holds 43 units,
whose 43 `GSNF###R` road coverages are byte-identical to Abacus's, beside 43 `GSNF###S` companion
coverages the package does not read; Abacus has seven units more (`BEN`, `BRO`, `FER`, `SCU`, `WEL`,
`WES`, `WIL`). So 1991 and 1996 stay on Abacus.

Still **not found anywhere**: an official user guide for the 1971, 1976 or 1981 Area Master File.
publications.gc.ca and Library and Archives Canada have none, neither Abacus deposit carries a
document, and the delivery holds only the record layout and the 1971 and 1976 reference lists for
those years. That is why `cs_domain_amf_class()` labels 1971 to 1981 by feature family while 1986
takes List A of the 1988 guide in full (`R/domains.R`). Two official documents that would settle it
are known by title only and are not online: "GRDSR: area master file documentation" (Statistics
Canada, 1981, 30 pp., listed in the bibliography of *Geography and the 1981 census of Canada*,
CS99-972-1982) and "Area Master File Documentation" (Geography Division, 1985, 26 pp.). The
Statistics Canada Library is where to ask.

**One secondary guide to the pre-1986 codes exists** (found October 2026): Claude Mallette and Guy
Lapalme, *Guide d'utilisation des "Area Master Files"*, Université de Montréal, Centre de recherche
sur les transports, publication 273, November 1982, on archive.org as `micro_IA40243510_2205`. It
describes the files as the centre had transformed them, in French, and does not say which census
its tapes were. Its "Liste A: Sortes de courbes" (p. 55, a scan whose text layer drops the code
columns -- read it off the page image) is the same (type, category) pair the files store:

| Sorte | Catégorie | Sorte de courbe |
|---|---|---|
| blanc | blanc | Rue |
| `0` | blanc | Autoroute adressable |
| `W` `S` `H` `R` `B` `I` | `N` | Rivières, canaux; rives, bords de lac; autoroutes; chemins de fer; ponts; île |
| `P` | `P` | Édifice |
| `D` `A` `T` | `A` | Rue "alias"; alias; édifice "alias" |
| `M` `U` `C` `O` `G` | `B` | Front. pol. (féd., prov. ou mun.); délimitation d'area; limite pour recensement; autre frontière statistique; frontière de propriété |

- **`OB` is "Autre frontière statistique"**, other statistical boundary -- the only definition of
  it found anywhere. The later official lists (1988, 1992, 1996) have no `O B` row; their `O` family
  is `O N`, topography. The arcs fit it in 1971 and 1976 (6 arcs each, one file, "GVRD WATERSHED
  BOUNDARY") and only loosely in 1981 (419 arcs in 15 files, none addressed: 153 unnamed, 126 the
  two proposed autoroutes, 72 "VERENDRYE DE LA", then pipeline, prison boundary, transmission line,
  ditch). The package still stores `OB` bare; labelling it would mean re-importing 1971 to 1981.
- **`Z` is in no list for these years.** Mallette and Lapalme have no `Z` row. Their second row is
  the nearest thing: a class whose type is set and whose category is blank, "autoroute adressable",
  which is the shape of the `Z` arcs (`Z` with a blank sub-type, arterials, some 60% addressed). The
  glyph in that row is a narrow oval unlike the `O` of `O B` -- most likely a zero -- and the
  national 1981 files carry no such class at all (`Z` is 547 arcs in 1971, 662 in 1976, none in
  1981). That it is the centre's recoding of `Z` is an inference, not something any source says.
- **What List A of the 1988 guide adds** (PDF pp. 45-49 of `AMF_86_Users_Guide.pdf`; the `O` and
  `Z` rows are on p. 49). It has `O N` (`FA` cliff, `DI` ditch, blank "Other Topography features")
  and `Z N` (`HY` hydroline, `TE` telephone line, `FE` fence, `PI` pipeline, blank "Other
  features") -- both with sub-type `N`. The early files carry neither: the raw bytes at positions
  18-19 are `OB` and `Z` followed by a blank. So the page defines neither code, but it shows where
  both went. Taking the nearest 1986 arc within 25 m of each arc's midpoint: of 1981's 419 `OB`
  arcs, 82 are "Other Topography features", 30 "Hydroline (Major)", 5 "Pipeline", 91 an ordinary
  street, 33 `E`, 27 "Highway multiple", 8 "Highway proposed", 75 nothing, the rest scattered over
  water, rail and boundary classes -- a catch-all that 1986 redistributed, mostly onto p. 49's own
  rows. Of 1976's 662 `Z` arcs, 577 are an ordinary unclassed street, 27 `E`, 17 ramp, 7 "Highway
  multiple", 13 nothing; against 1981, 645 are already an ordinary street.
- **The nearest official reading of the early `Z`** is on p. 45, not p. 49: List A's second row is
  type `E`, sub-type blank, any List B street type, "Addressable Multiple street & public access
  lane" -- the only other class with a type letter over a blank sub-type, and like `Z` it is
  addressed (1986 `E`: 9,641 arcs / 1,471 km in 100 files, 59% addressed; `Z`: 72.9% addressed in
  1971 over 6 files, 64.5% in 1976 over 10) and carries ordinary street types (`Z` in 1976: 504
  blank, 156 `BV`, 2 `DR`). It is the same kind of class, not the same class: the arcs do not
  carry over.
- Its Appendice A quotes Statistics Canada's own documentation in English: "There are four kinds of
  features. (a) addressable (b) non-addressable (c) alias (d) point streets. The last three will
  contain a feature type to identify them (see list) and they will not contain any addresses.
  Addressable features will have a blank in the feature type and the address fields must be
  filled." The list it refers to is not reproduced.

The citable source for the coverage story is the 2006 Census Dictionary note on the road network
file, `census-recensement/2006/ref/dict/geo041a-eng.cfm`. The README links it; the story itself is
told in `readme-cuttings.md`.

**Why the manifest takes the coverages, not the Abacus shapefiles.** Both SNF deposits ship the
ArcInfo interchange coverages *and* shapefiles derived from them, and for 1991 the derivation is
broken: four units (Halifax `GSNF205`, Chicoutimi-Jonquiere, Montreal, Toronto) ship no `ARC_ID`
column at all, and in them every field after a street name containing a comma is shifted one
position -- 13,593 arcs / 2,309 km carry a `class` that is really the tail of a name, and 2,344 more
have had an apostrophe deleted. `HULL_OTT` merged `CLASS` and `TYPE` and blanked 345 `Z...` names.
1996's shapefiles are faithful field for field; it was switched over on principle. Reading the
coverages costs nothing and fixes all of it -- the arc counts and total length are unchanged, every
arc carries an identifier, and `roads_only` gains exactly the five arcs the audit predicted. 1991's
Lambert twins (`LSNF205`, `OT_HULL`) exist only in the derived formats, which is why `file_exclude`
is `NA`.

**CanVec is not a source, and its 1944 is not a road date.** NRCan's CanVec record
(`open.canada.ca/data/en/dataset/8ba2aa2a-7bb9-4448-b4d7-f164409fe056`) advertises 1944-2019, which
is the min/max of the per-feature `datemin`/`datemax` acquisition dates, not a series. Measured on
the 50K Transport tiles: PE `road_segment_1` is 18,509 arcs, `datemin` 2005-2019, 14,614 at 2010;
NT is 6,918 arcs, 1999-2017, 6,159 at 2010; every arc in both carries a populated `geobase_id`, so
the road content is the National Road Network imported around 2010. The pre-1976 dates are on
unrefreshed NTS content -- NT `trail_1` runs 1946-2018, mode 1970. A current-state product also
records no removals. Two earlier editions exist (`archive/canvec_archive_20130515/`,
`archive/canvec+_archive_20151029/`), i.e. NRN 2013/2015/2019. What it does have is fuller NRN
attribution: of PE's 18,509 arcs, 15,456 (83%) carry a left address range and 17,896 (97%) an
official street name parsed into article/body/type/direction per side. OGL-Canada, so usable as an
external check on the modern end -- not as a vintage.

## What each vintage holds, and what the road filter costs it

| Vintage | Arcs | km | After `roads_only` | km | Coverage |
|---|---|---|---|---|---|
| 1971 | 215,399 | 31,882 | 185,211 | 25,847 | urban: 34 files, 15 metropolitan areas, 7 provinces |
| 1976 | 431,844 | 65,709 | 353,216 | 50,468 | urban: 99 files, 33 areas, 9 provinces |
| 1981 | 529,158 | 80,100 | 426,755 | 60,437 | urban: 135 files, 39 areas |
| 1986 | 909,065 | 135,232 | 573,008 | 85,898 | urban: 194 files, 54 areas |
| 1991 | 599,625 | 160,778 | 503,469 | 104,296 | urban |
| 1996 | 629,574 | 167,238 | 528,970 | 109,182 | urban |
| 2001 | 2,053,112 | 1,736,503 | 1,880,600 | 1,328,881 | national |
| 2005 | 1,864,299 | 1,328,206 | unchanged | | national |
| 2006 | 1,869,564 | 1,326,099 | unchanged | | national |
| 2011 | 1,973,932 | | unchanged | | national |
| 2016 | 2,163,058 | | -194 arcs | -30.1 | national |
| 2021 | 2,242,117 | ~1,170,000 | -203 arcs | -27.3 | national |

- 2001 is 1,329,337 km with its 360 under-construction arcs left in; the 388,345 km that separates
  it from 2006 was entirely census topology (`BO` 167,916 arcs / 388,345 km, `1536` 1,625 / 18,650,
  `SB` 2,611 / 171 -- none named, typed or addressed). `1011` is the ordinary street, 688,063 arcs;
  `U` is 249,126 arcs, 83% named; `1307` (346 unnamed arcs / 686 km) is kept.
- 2005 is the one Road Network File before 2011 with a class column, and all six classes are road,
  so `roads_only` emits no filter for it. In arcs / km / named / with an address field: `ST` Streets
  1,639,192 / 981,010 / 1,350,798 / 1,028,106; `HI` Highways 108,243 / 128,359 / 97,953 / 40,144;
  `UTR` Utility roads 83,246 / 159,316 / 396 / 35; `UR` Unclassified roads 26,561 / 57,649 / 169 /
  71; `CON` Connector roads 6,316 / 1,560 / 60 / 6; `BT` Bridges and tunnels 741 / 312 / 90 / 4.
  The arcs agree they are roads: on a 2% sample, 99.0-100% of every class has a 2006 arc within
  15 m (`UTR` 99.3%, `UR` 99.0%), and the few named `UTR` and `UR` arcs are Alberta range and
  township roads. No arc has a rank, and the file has no region columns. `NGD_ID` is not unique:
  1,795,438 distinct values over the 1,864,299 arcs.
- 1996's non-road classes are 100,519 arcs / 58,003 km; 1991's 96,156 / 56,482 -- the same ~35%.
  1991's class vocabulary is a strict subset of 1996's (1996 adds `GJA`, `GCO`, `U`, `GCH`).
- 2006 carries more length than 2021 (1.33M vs 1.17M km) because it holds far more very long arcs:
  22,486 over 5 km against 13,055. Not an import bug -- neither table has a duplicate geometry.
- What the Area Master File road filter drops, in arcs / km. 1971: boundary 7,875 / 2,361, water
  16,471 / 2,175, rail 4,227 / 1,248, property 1,609 / 249, other 6 / 1. 1976: boundary 17,553 /
  6,393, water 48,275 / 5,616, rail 9,609 / 2,720, property 3,185 / 511, other 6 / 1. 1981: boundary
  21,373 / 7,871, water 65,196 / 7,743, rail 12,385 / 3,428, property 3,030 / 482, other 419 / 138.
  1986: water 216,933 / 18,228, boundary 39,930 / 13,480, rail 35,255 / 7,399, utility 13,484 /
  5,422, property 20,160 / 3,832, path 5,889 / 499, topography 4,340 / 448, planned road 66 / 27.
  The non-road share of length climbs 19% -> 23% -> 25% -> 36%; 1986 is where the file becomes the
  topographic base the Street Network File inherits.
- What it keeps: the unclassed arc, which is the ordinary street (1971 181,459 / 25,011 km, 1976
  343,747 / 48,365, 1981 415,565 / 57,972, 1986 538,201 / 81,019), and the classed roads (3,752 /
  836, 9,469 / 2,104, 11,190 / 2,464, 34,807 / 4,879).
- Names and addresses, all arcs: 1971 all named, 176,933 typed, 145,309 with an address field; 1976
  all named, 332,966 typed, 261,146 addressed; 1981 466,651 named, 403,376 typed, 309,863 addressed;
  1986 all named, 521,722 typed, 369,998 addressed.
- **1981 is missing 62,507 names (11.8%) and they are not recoverable.** Nineteen of its files had
  9,039 feature headers put through the detail-record conversion, which destroyed characters 6-13
  of each name; type and direction are recovered, the name is left missing (`R/amf.R`).
- `arc_id` is unique only within a source file: 1991 has 599,038 distinct values over 599,625 arcs,
  1996 628,124 over 629,574. `(source_file, source_id)` is the key, and it is unique in all four
  national Area Master Files (the retired Abacus `bc.data` of 1981 had 22 collisions even so).

## Roads a vintage drew before they were built

| Vintage | Class | Arcs | km |
|---|---|---|---|
| 1996 | `HPR` Highway proposed | 85 | 53.3 |
| 2001 | eight "under construction" descriptions | 360 | 455.5 |
| 2016 | `28` Planned | 194 | 30.1 |
| 2021 | `28` Planned | 203 | 27.3 |

The Street Network File records the same thing a second way and it is *not* filtered: the
fixed-width `NAME` field packs `PROP.`/`PROJ.` as a suffix on 2,182 arcs / 470 km in 1991 and 932 /
260 km in 1996, an order of magnitude more than `HPR`, on arcs classed as ordinary highways. The
packing affects 13,340 of 1991's 580,020 named arcs (2.3%) and 1,399 of 1996's 609,009 (0.2%);
those names never match a modern `name_fold`.

**Why `roads_only` takes a status vector.** Nothing outside `category == "road"` carries an address
worth having: of 916,037 non-road arcs across the eleven imported vintages (1971 30,188, 1976
78,628, 1981 102,403, 1986 335,991, 1991 96,156, 1996 100,519, 2001 172,152), 646 carry any address
field -- 1971 118, 1976 158, 1981 368, 1986 none, 1996 2. The Area Master File ones are water and
boundary chains with one stray field and no street type (Calgary's Glenmore Reservoir shoreline,
`at_l = 2`), except thirteen 1976 Dartmouth arcs of `YSE RD` classed as a stream with real ranges;
1996's two are `BLADEN ST` filed as an enumeration-area boundary and `GREGOIRE RD` as an associated
feature. Roads under the wrong class, in other words, and too few to chase. Walkways carry none at all -- 1991 `FWA` 25 arcs, 1996 `FWA` 38 and `FTR` 1,469, zero
addressed between them. But 177 of 2016's 194 `Planned` arcs are addressed block faces over 97
distinct names, every one of which appears in 2021. (2021: 10 of 203; 2001 under construction: 1 of
360.) Verified end to end: `roads_only = c("operational", "unknown", "planned")` gives 2016
2,163,058 arcs / 1,356,625 addressed against the default's 2,162,864 / 1,356,448, and 1996 529,055
arcs while still dropping the 100,519 non-road ones.

## Geometry across the series

Calibrated against 2021 over the Vancouver CMA:

| Vintage | `recall_p50` (m) | Calibrated tolerance |
|---|---|---|
| 1971 | 11.1 | 35 m |
| 1976 | 11.4 | 37 m |
| 1981 | 10.9 | 34 m |
| 1986 | 10.8 | 33 m |
| 1991 | 15.6 | 38 m |
| 1996 | 15.7 | 38 m |
| 2001 | 11.2 | 36 m |
| 2006 | 11.6 | 37 m |
| 2011 | 0 | 10 m (floor) |
| 2016 | 8e-7 | 10 m (floor) |

The Area Master File geometry is *not* the weak link its age suggests -- over Vancouver all four
years register better than 1991 and 1996. What improves after 2006 is vertex density, not registration; 2011 and
2016 clamp to the floor because they share 2021's base geometry. The 40 m upper clamp is a Calgary
result (2001, 2006 and 2011 there, 1996 at 39 m): `name_disagree` stays flat (0.12 to 0.14) all the
way out, so the bound is binding, not the data.

**Over Calgary the Area Master Files are systematically displaced, and the build warns about it.**
Eleven-vintage Calgary CMA build, against 2021 (tolerance, `recall_p50`, `disagree_25`, mean dx,
dy in EPSG:3347 axes): 2016 10 m, ~0, 0.011, 0.0, 0.0; 2011 40, 13.5, 0.125, 0.35, -3.85; 2006 40,
13.1, 0.123, 0.58, -3.40; 2001 40, 12.1, 0.118, 0.76, -2.77; 1996 39, 12.3, 0.123, 1.44, 5.08; 1991
35, 11.8, 0.114, 1.77, 5.93; 1986 40, 16.8, 0.173, 6.92, 8.48; 1981 40, 16.6, 0.168, 6.89, 9.17;
1976 40, 17.3, 0.188, 7.11, 9.34; 1971 40, 19.9, 0.233, 7.67, 12.92. The four AMF years are 10.9,
11.5, 11.7 and 15.0 m off, all the same way, which is what trips `shift_warn_m = 10` four times;
the warning does not name the vintage. Vancouver's AMF offsets are about 2 m (dx -1.9 to -2.2, dy
0.4 to 1.1), smaller than 1991/1996's there (-9.3, -2.4).

**A plausible partial cause, not established: the NAD27 shift is applied without a grid.** Neither
DuckDB spatial's PROJ nor the local sf (PROJ 9.5.1, network off) has the NTv2 grid, and the two
agree to 1e-10 m, so the import's NAD27 -> NAD83 step is the grid-less approximation. Applying the
NTv2 pipeline explicitly moves a Calgary point (706000, 5660000, UTM 11) by (-1.85, -18.74) m and
Main and Hastings in Vancouver by (2.59, -4.58) m relative to what is stored. Rotated out of the
Lambert axes (convergence about -20 degrees at Calgary), 2021 sits 11 to 15 m north and about 3 m
east of the Calgary AMF; the grid would move the AMF about 19 m north, an overshoot of 4 to 8 m. One
point per city, not a re-import. 1991 and 1996 are NAD27 too and sit 5 to 6 m off in dy at Calgary.
Acting on it means a grid dependency, a `cs_schema_version()` bump and a re-import.

- **The AMF datum is NAD27, verified rather than assumed.** The 1976 node at Main and Hastings
  (492833, 5458561) lands within 13 m of the intersection through EPSG:26710 and 200 m away through
  EPSG:26910. In bulk, the share of national AMF road length with a 1991 arc within 20 m / 40 m of
  its midpoint is 88.3% / 95.9% for 1971, 86.5% / 92.8% for 1976, 93.5% / 96.9% for 1981 and 95.8% /
  97.8% for 1986; against 2021, 73.7% / 93.3%, 68.9% / 89.1%, 69.8% / 91.0% and 69.9% / 89.8%, the
  gap being 2021's finer digitization.
- **AMF node-pair segments are block faces.** Median length 103 m in 1971, 100 m in 1976, 99 m in
  1981 and 90 m in 1986. Of the fully addressed faces,
  100% have the same parity at both ends of a side, 100% opposite parity across the street, and 96%
  span under 200 civic numbers.
- **Positional error between vintages is noise, not a registration shift.** Same-name 2006-2021
  pairs: mean dx 0.6 m, dy -1.28 m (1996: 1.16, 4.82) but sd about 13 m in both axes, median
  midpoint displacement 12.6 m. No affine correction is warranted; a generous tolerance is. A mean
  displacement over 10 m raises a warning, since that *would* be a shift.
- **2006's long arcs are coarsely generalized where 2021's are finely digitized.** Of 30,759 2006
  Calgary arcs, 6,406 match no 2021 arc, and they are systematically long and multi-vertex (p90
  length 484.7 m vs 311.8 m matched; 3.58 vertices vs 2.85, rising to 10.5 in the 1-5 km bucket):
  Deerfoot and Glenmore Trail, Township and Range Roads, numbered highways. This is what the name
  rescue exists for -- without it Calgary reports ~1,180 km of spurious 2006 road loss.

## Matching at scale

- The name rescue without grid blocking pairs **956 million** 2006-2021 arcs before any distance
  test (2021 holds 1.94M named arcs over 130,105 distinct folded names; `MAIN` alone occurs 12,884
  times), and burned 110 minutes of CPU without completing. `cs_build_rescue_index()` makes the key
  `(name_fold, cx, cy)`; verified bit-identical on Calgary -- same 74,609 segments, same 12,329 km.
- The coverage pass in `cs_tag_spine()` is the remaining national blocker: 18.6 GiB then 31.8 GiB of
  DuckDB temp storage, disk exhausted. `within = NULL` is accepted but is not the supported scale.
- **The ordinal fold is load-bearing.** Inside the Vancouver CMA the AMF and SNF vintages carry zero
  ordinal-suffixed arcs against 2001's 4,511 and 2021's 5,043, and the pre-2001 lineage puts 15th
  Avenue 40-48 m north of where 2001 onward puts it (49.25862 / 49.25874 / 49.25832 / 49.25819 at
  Maple) -- wider than 1976's 37 m tolerance, so rule A correctly declines and rule B is the whole
  safety net. Unnormalized, one Kitsilano box emitted the road twice: 144 segments / 21.69 km dated
  2001 and named `15th`...`27th` beside 145 / 21.44 km retiring after 1996 and named `15`...`27`.
  Normalizing creates **zero** new name collisions in either region and recovers 246 segments /
  33.19 km CMA-wide; Calgary, the control, moves by one segment / 0.2 km.
- Crosswalk fan-out if joined on `source_id` alone, measured on the Vancouver build as it stood on
  the Abacus extracts: 1976 48,695 rows to 48,813, 1996 69,912 to 70,329, some segments picking up two different names.

## Build benchmarks

| Build | Vintages | Time | Segments | km |
|---|---|---|---|---|
| Vancouver CMA | 11 (1971-2021) | not timed | 87,277 | 11,379 |
| Calgary CMA | 11 (1971-2021) | not timed | 81,232 | 12,529 |
| Vancouver CMA | 9 (1976-2021) | 42 s | 85,029 | 11,361 |
| Calgary CMA | 6 (1996-2021) | ~25 s | 75,662 | 12,397 |
| Calgary CSD envelope | 7 (1991-2021) | 19 s | 65,631 | 8,143 |

Per-year length, strictly monotone in each:

- Vancouver CMA, eleven vintages: 1971 6,340 -> 1976 6,490 -> 1981 7,064 -> 1986 8,787 -> 1991
  9,314 -> 1996 9,470 -> 2001 9,955 -> 2006 10,079 -> 2011 10,220 -> 2016 10,380 -> 2021 10,493 km.
  AMF source files in the build: 12 in 1971 and 1976, 18 in 1981 (adds the District of North
  Vancouver, New Westminster, Port Coquitlam, Port Moody, White Rock, `GVSA`), 18 in 1986 (adds
  Langley 4,642 rows, Maple Ridge 2,252, Pitt Meadows 665).
- Calgary CMA, eleven vintages: 1971 2,479 -> 1976 2,948 -> 1981 3,492 -> 1986 3,848 -> 1991 4,421
  -> 1996 4,864 -> 2001 9,256 -> 2006 10,146 -> 2011 10,645 -> 2016 11,088 -> 2021 11,505 km. New
  since 2006 2,008 km; retired 1,025 km; in 2006 and gone by 2021 713.3 km, of which 148 km inside
  the City of Calgary CSD; interior-gap length 359.4 km (2.87%); 12,965 of 2006's 62,345 crosswalk
  rows are `name_rescue`; 356 distinct `year_key`s.
- Vancouver CMA: 1976 6,489 -> 1981 7,066 -> 1991 9,316 -> 1996 9,472 -> 2001 9,955 -> 2006 10,079
  -> 2011 10,220 -> 2016 10,380 -> 2021 10,493 km. 643 superseded pieces / 15.7 km dropped. (On the
  Abacus extracts it was 85,044 segments / 11,365 km, 1976 6,494 and 1981 7,069 km: the national
  files move the Vancouver build by a few kilometres and no conclusion.)
- Calgary CMA: 1996 4,864 -> 2001 9,255 -> 2006 10,145 -> 2011 10,643 -> 2016 11,088 -> 2021
  11,505 km. 163 superseded pieces / 4.3 km dropped; without that drop, 9 of 3,744 rows violated the
  `last_year == spine_vintage` invariant.
- Calgary CSD envelope: 1991 4,427 -> 1996 4,870 -> 2001 5,930 -> 2006 6,567 -> 2011 6,919 -> 2016
  7,422 -> 2021 7,727 km, 1991 calibrating to a 35 m tolerance.

`first_year` is dominated by coverage, not construction. In the eleven-vintage Vancouver build 1986
alone adds 1,850 km CMA-wide (16.3%), which is the Area Master File taking in Langley, Maple Ridge
and Pitt Meadows; 1991 adds 618 km, 1981 678 km, 1976 180 km. Inside the City of Vancouver CSD,
where coverage was complete in 1971, 93.3% of length (1,502 km) has `first_year == 1971` against
55.7% (6,340 km) CMA-wide. (In the nine-vintage build, without 1986, 1991 carried the step: 2,426
km.) `temporal_network_region_drift()` recovers the annexation of 54.7 km of road
into Airdrie between 2011 and 2016.

Import timings for the two awkward vintages: 2001's MapInfo file scans in 31 s and imports end to
end in 62 s (the ArcInfo coverage of the same release needs a 90-second conversion first and scans
at ~230 arcs a second, over two hours); the 51 1991 coverages read in 143 s, a whole vintage in
about four minutes.

## Renames

Worked end to end in `vignettes.orig/canstreet-renames.Rmd`, whose knitted output carries the
funnel. The pool it draws on: `match_kind = 'geometry'` pairs whose folded names disagree run 10,524
for 1976 down to 587 for 2016 over the Vancouver CMA, and roughly half of 2001's 8,876 have a blank
name on one side -- a road that gained a name rather than one that changed it. There is deliberately
no `temporal_network_renames()` accessor: the classification is judgement about one region's naming
conventions, not something the package should assert. Over the eleven-vintage build, City of
Vancouver: 20,398 segment-steps / 2,305 km written differently, 4,114 / 313 after folding, 3,728 /
286 with both sides named; of those, loosely matched 2,352 / 163 km, candidate rename 834 / 74.8,
street type moved 356 / 32.6, spelling convention 186 / 15.5; 100 reversed pairs; 205 pairs / 42.4
km left. `MAPPLE` for East Boulevard is 1976 alone (1971, 1981 and 1986 have `EAST BOULEVARD`), so
with 1971 in the build it is a reversal, not a correction; `LANEYS MILL` is 1981 alone and has no
earlier file to reverse against. Kent Avenue: `KENT` -> `E KENT` 83 and -> `W KENT` 27 in 2011-2016.
Note the blind spot -- rule B joins on exact
folded-name equality, so a road that was both renamed and coarsely digitized reads as a retirement
plus a new road.
