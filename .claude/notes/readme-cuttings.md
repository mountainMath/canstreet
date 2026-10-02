# README cuttings

What the README said before it was shortened (October 2026) and no longer says. The README is now
the short user-facing overview; this is the longer account of the series, kept because it took work
to establish and may be wanted again -- for a vignette, a pkgdown article, a paper's data section,
or an answer to "why does the package do that". Not user documentation, and not shipped.

The prose is kept close to how it read, so a section can be lifted back out. The full original is
`git show bba60b9:README.md`. Numbers here were taken from `corpus-facts.md`, which stays the
authority for any figure; each section says where the same material still lives in the package, if
anywhere.

Still in the README, so not repeated here: the vintage table, the two dictionary links, "topological
accuracy takes precedence over absolute positional accuracy", not routable, address ranges thin
outside the cities (74% / 43% in 2011, 71% / 49% in 2016), the non-road lengths per vintage, the
2001 NGB quotes and the 15th Avenue example, and the `roads_only` status vector.

## One series under three names

*Still elsewhere: nowhere in the package. The README now only links the two dictionary entries.*

The three products are one lineage, not three datasets. Statistics Canada's [2006 Census Dictionary
note on the road network
file](https://www12.statcan.gc.ca/census-recensement/2006/ref/dict/geo041a-eng.cfm) sets out the
succession and what it cost in coverage: **area master files** from 1971 to 1991, **street network
files** for 1996, and **road network files** from 2001 on. Everything before 2001 covered large
urban centres only -- under 1% of Canada's land area, and about 35% of its population in 1971, over
50% in 1981, 57% in 1986 and 62% in 1991 and 1996. 2001 is the first file covering the whole
country, and it is also the year the files carried boundary arcs alongside the roads (the note
confirms that was deliberate); the free download begins with the 2005 release. This is why a
segment's `first_year` so often marks the year the file reached a place rather than the year the
road was built.

The [2011 Census Dictionary entry for the Road Network
File](https://www12.statcan.gc.ca/census-recensement/2011/ref/dict/geo041-eng.cfm) gives the
official account of the series and its coverage by census year: road network files covering the
entire country for 2011, 2006 and 2001; street network files covering large urban centres for 1996;
and area master files, also urban only, for 1991 and every census back to 1971. All of them are in
the package. The 1971, 1976, 1981 and 1986 area master files are the national sets -- 34 files over
15 metropolitan areas in 1971, growing to 194 files over 54 by 1986. Statistics Canada does not
serve them online, so the package fetches them from a copy hosted by MountainMath: one zip per
census, the files as Statistics Canada delivered them, with the record layouts and the 1988 user
guide alongside. 1991 is here as its Street Network File. The source manifest is a plain data table,
so a further year can be added without code changes.

## The naming is not consistent between editions of the dictionary

*Still elsewhere: nowhere. This is the reasoning behind the `product` column's values.*

The [2001
entry](https://www12-2021.statcan.gc.ca/english/census01/products/reference/dict/geo041.htm) applies
the later name to the whole back series -- "1996, 1991, 1986, 1981, 1976, 1971 (Street Network Files
-- cover large urban centres only)" -- and then dates the change in one line at the foot of the
entry: "Prior to 1996, Street Network Files were called Area Master Files (AMFs)." The 1996 Abacus
deposit says the same from the other side, describing the street network files as "formerly known as
the Area Master Files (AMFs)" and "first created in the early 1970s". Two names, one product,
renamed at 1996 -- the change of name by itself marks nothing about the files.

By 1991 the older acronym had in any case become the name of a *format*: that deposit is titled a
Street Network File and ships two user guides, one for the "ARC/INFO export format" and one for the
"AMF format". The `product` column splits on the file rather than on the dictionary -- `AMF` for the
four mainframe flat-file vintages, `SNF` for the two ArcInfo coverage vintages. That puts 1991 with
the street network files, where the 2006 and 2011 dictionaries put it with the area master files.

## The Area Master File format, and how good its geometry is

*Still elsewhere: the format in the `R/amf.R` header and `?read_amf`; the lost 1981 names in
`NEWS.md`; the Vancouver calibration in `vignette("canstreet-vancouver")`. The README keeps one
sentence pointing at `read_amf()`.*

The area master files are not a GIS format and no GDAL driver reads them: they are mainframe flat
files, one per municipality, one fixed-width record per line, describing each street as a chain of
nodes in NAD27 UTM. `read_amf()` parses them into block-face segments carrying the street name, the
feature class and the civic address range on each side, and reads the two other transcriptions the
format circulated in as well -- one of them an EBCDIC original whose coordinates are packed decimal.

They import like any other vintage, and their geometry stands up better than their age suggests:
between 87% (1976) and 96% (1986) of their road length has a 1991 Street Network File arc within
20 m of its midpoint, and 93% to 98% within 40 m. Calibrated against 2021 over the Vancouver CMA,
the median positional disagreement on same-name roads is 11.4 m for 1976 and 10.9 m for 1981 --
lower than the 15.7 m of the 1991 and 1996 street network files. (Calgary is the counter-example:
its four AMF years sit a steady 11 to 15 m off in one direction; see `corpus-facts.md`.)

One thing did not survive the decades: the 1981 files arrived with part of their name fields
overwritten, so 62,507 of that year's 529,158 segments keep their type, direction and geometry but
have no name.

## What the 2001 break means for the matcher

*Still elsewhere: the quotes and the 15th Avenue example are in the README; the consequence is in
the `R/tnet.R` header.*

2001 is not the 1996 street network file extended over the rest of the country, it is a different
base, moved. The 15th Avenue shift of some 40 m is further than the matching tolerance those years
calibrate to. It is why the matcher carries a second rule keyed on street names rather than on
distance alone, and a second reason to distrust `first_year == 2001` -- national coverage begins in
that year, and so does a different geometry.

## Roads a vintage drew before they were built

*Still elsewhere: `?canstreet_road_classes`, `?build_temporal_network`, the `R/classes.R` header.
The README now says only that some vintages contain proposed, planned or under-construction roads.*

Whether a road was there in the year that carries it is a separate question from whether an arc is
a road, and every era has a way of drawing one that was not: 1996 classes Highway 403, Highway 407
and Autoroute 50 "Highway proposed", 2001 writes "under construction" into eight of its class
descriptions, and 2016 and 2021 class about 200 subdivision streets apiece "Planned".

Why `build_temporal_network()` applies the road filter by default: left in, every river, rail line
and provincial boundary reads as a road that has since been removed, and every planned street dates
its road to the year that anticipated it rather than the year that built it.

## Why the planned roads are worth letting back in

*Still elsewhere: `?get_road_network` (the `roads_only` argument). The README keeps the example and
"planned roads often carry address block data".*

`roads_only = c("operational", "unknown", "planned")` is a geocoding answer rather than a
network-history one. Across the whole series the features that are not roads carry no addresses
worth having -- of 916,000 arcs classed as watercourse, railway, boundary, property, hydro line or
walkway, 646 carry any address field. Nearly all are a single stray number on an area master file
shoreline or boundary chain, and the few with a real range are roads filed under the wrong class.
The roads a vintage drew early are different: 177 of 2016's 194 "Planned" arcs are addressed block
faces, and every one of their street names is in the 2021 file, so those are real addresses on
streets that were built.

## The class and rank vocabularies, vintage by vintage

*Still elsewhere: the `R/domains.R` header and `?canstreet_domains`. The README now says only that
codes are inconsistent over time and that `canstreet_domains()` translates back.*

`class` and `rank` are stored as labels rather than as the codes the source files carry, so a road
classed `23` comes back as `Local`. Statistics Canada publishes the vocabulary once per census year
and it genuinely changes between them -- 2016 defines class `95` as a second "Unknown", 2021 retires
it and adds `87` for winter roads, 2001 uses a numeric vocabulary with no code in common with 2011
onward, and the 1991 and 1996 Street Network Files classify *features* rather than roads -- so the
label a code gets depends on the vintage it came from. `canstreet_domains()` returns the tables,
which is what you need to go back from a label to a code, and `canstreet_road_classes()` says which
of the values in them are road.

The vocabularies are read from primary sources: the reference guide shipped inside each Road Network
File archive, the Street Network File User Guide from the Abacus deposit, and the 2021 Census
attribute domain values page. The area master files get theirs from the one guide that survives for
them, The Area Master File User Guide of January 1988, which ships in each hosted archive. Its
feature classification is a (feature type, sub-type, street type) triple. The 1986 file stores all
three, so its classes are the Street Network File's, label for label -- "Highway multiple" is one
string in 1986, 1991 and 1996. The 1971 to 1981 files store the first two only, so there a class
names a family: `HN` is a highway, `MB` a political boundary, `SN` a shoreline.

The README closed this with "Where no vocabulary was ever published -- 2005 to 2010, and the two
early area master file codes the guide does not account for -- the codes are kept as they are."
**That sentence was wrong about 2005 and should not be reinstated as written.** Checked in October
2026 against the archives and their bundled guides:

- **2005 has a published vocabulary.** The guide inside `grnf000r05a_e.zip` (92-500-GIE2005001,
  p. 19) defines six classes, and the file carries exactly those six: `ST` streets, `HI` highways,
  `UTR` utility roads (not addressable), `UR` unclassified roads, `CON` connector roads (not
  addressable), `BT` bridges and tunnels (not addressable). The guide adds that "road classification
  has not been maintained" and that roads in that release "are not ranked". `R/domains.R` now carries
  them as `cs_domain_rnf_2005_class()`, and all six count as road.
- **2006 to 2010 have nothing to label.** None of the five files has a class or rank column; the
  2006 guide says the attribute "is no longer maintained and has subsequently been removed".
- **Of the two early area master file codes, `OB` has one secondary definition and `Z` none.** No
  delivered document defines either for 1971 to 1981. A 1982 Université de Montréal guide gives
  `O B` as "autre frontière statistique"; nothing gives `Z`. The package keeps both bare. The
  source and what it does and does not establish are in `corpus-facts.md`.

## Why CanVec is not a fourth source

*Still elsewhere: nowhere in the package; the measurements are in `corpus-facts.md`.*

Natural Resources Canada's [Topographic Data of Canada -- CanVec
Series](https://open.canada.ca/data/en/dataset/8ba2aa2a-7bb9-4448-b4d7-f164409fe056) advertises a
temporal coverage of 1944 to 2019, which makes it look like the one national source reaching back
further than these files do. It is not. CanVec is a current-state topographic snapshot rather than a
series -- its update frequency is "Not Planned" and its distribution has been frozen since 2019 --
and the 1944 is a per-feature acquisition date, `datemin`/`datemax`, recording the compilation of
the National Topographic System sheet the feature was digitized off. Sheets nobody had reason to
revisit still carry their original date.

Roads are not among them. In the 50K Transport tiles the road segments are recent everywhere: Prince
Edward Island's 18,509 arcs span 2005 to 2019 with 14,614 of them at 2010, and the Northwest
Territories' 6,918 span 1999 to 2017 with 6,159 at 2010. Every one carries a populated `geobase_id`,
because the road content is Natural Resources Canada's National Road Network dropped in around 2010.
The old dates sit on what was left alone: Northwest Territories `trail_1` reaches back to 1946, with
its own mode at 1970. Those dates are the lead worth following if pre-1971 street geometry is ever
wanted -- but the lead is the topographic sheets themselves, not CanVec.

An old date would in any case date a compilation rather than a network. A current-state product
records no removals, so a street that existed in 1985 and was gone by 1995 leaves nothing behind in
it, which is the one thing a series of snapshots gives and a snapshot cannot. The distribution FTP
does keep two earlier editions alongside the current one (`archive/canvec_archive_20130515/` and
`archive/canvec+_archive_20151029/`), making CanVec a three-point series -- but a series of the
National Road Network of 2013, 2015 and 2019, inside the years the Road Network Files already cover
and thinner than they are.

What CanVec holds that these files do not is that National Road Network attribution, which is
markedly fuller than Statistics Canada's: 83% of those Prince Edward Island road segments carry a
left-side civic address range and 97% an official street name already parsed into article, body,
type and direction on each side, against the 43-74% address coverage of the Road Network Files -- on
a province that is mostly rural, where these files are at their thinnest. It is distributed under
the Open Government Licence -- Canada, so unlike the DMTI Spatial collection on Abacus it is free to
use. That makes it a way to check the modern end of this series from outside it, not a vintage to
add to it.

## Smaller things the edits dropped

- A national temporal build "does not finish yet" became "resources intensive and not recommended".
  The measured state is unchanged: a national two-vintage build spilled 31.8 GiB of DuckDB temporary
  storage and exhausted the disk (`corpus-facts.md`, "Matching at scale").
- That the early vintages carry more than roads was introduced as "one thing the dictionary does not
  say, established here by reading the files" -- it is this package's finding, not Statistics
  Canada's statement, which matters if it is ever cited.
