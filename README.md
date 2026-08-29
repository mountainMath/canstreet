
# canstreet

<!-- badges: start -->
<!-- badges: end -->

This package facilitates downloading and processing the historical Statistics Canada road/street network files. This enables understanding how the road network has evolved over time, which can be useful for a range of analysis applications, including in economics, urban planning, transportation studies, and historical research.

The package provides a uniform base for this to enable reproducible and collaborative work in this space.

## Functionality

The package provides basic functionality:

* Download and cache the historical road/street network files from Statistics Canada.
* Identify common road/street segments across different years even when geocoding accuracy has changed over time.
* Create a temporally unified street network dataset that tags segments according to the years they were present in the network.
* Facilitate common geo-processing tasks like querying the data with spatial filters.

## Installation

```r
remotes::install_github("mountainMath/canstreet")
```

## Set a cache path first

The network files are large -- a national vintage is 200-350 MB compressed and
about 2.2 million segments -- so `canstreet` keeps both the downloaded archives
and the harmonized database in a cache directory. Without one, everything goes
to `tempdir()` and is re-downloaded next session:

```r
library(canstreet)
set_canstreet_cache_path("~/data/canstreet", install = TRUE)
```

`install = TRUE` writes `CANSTREET_CACHE_PATH` to your `.Renviron` so it applies
to every future session. You can also set the `canstreet.cache_path` option, or
the environment variable directly; `canstreet_cache_path()` reports what is in
effect, and `show_canstreet_cache_path()` says where the setting came from.

## Documentation

Reference documentation for every function, along with the vignettes, is at
<https://mountainmath.github.io/canstreet/>.

## Usage

```r
library(canstreet)
library(dplyr)

# What is available, and what is already cached.
list_road_network_vintages()

# First call downloads and imports; later calls are instant.
roads <- get_road_network(2021)
```

`get_road_network()` returns a lazy table, so filters and aggregations run
inside the database rather than pulling millions of rows into R:

```r
roads |>
  group_by(pruid_l) |>
  summarize(km = sum(len_m, na.rm = TRUE) / 1000) |>
  collect()
```

Materialize a result as an `sf` object with `collect_road_network()`. A spatial
filter over a single vintage uses that vintage's R-tree index:

```r
bbox <- sf::st_bbox(c(xmin = -123.2, ymin = 49.2, xmax = -123.0, ymax = 49.3),
                    crs = 4326)

vancouver <- get_road_network(2021, within = bbox) |>
  collect_road_network()
```

Several vintages at once are stacked, which is the starting point for looking at
change over time:

```r
get_road_network(c(1996, 2006, 2021)) |>
  group_by(vintage) |>
  summarize(km = sum(len_m, na.rm = TRUE) / 1000) |>
  collect()
```

Use `export_road_network()` to write GeoParquet for use from Python, QGIS or
DuckDB, `list_canstreet_cache()` to see what the cache holds, and
`remove_canstreet_cache()` to evict a vintage. `vignette("canstreet")` walks
through all of this against real files.

## Tracking the network through time

`build_temporal_network()` matches segments across vintages and writes a single
table in which every segment carries the list of years it is present in.

```r
# Any sf polygon will do. cancensus is one way to get one, and is not a
# dependency of this package:
cma <- cancensus::get_statcan_geographies("2021", level = "CMA") |>
  dplyr::filter(CMANAME == "Calgary")

calgary <- build_temporal_network("calgary", c(1996, 2006, 2011, 2016, 2021),
                                  within = cma)

calgary |>
  group_by(year_key) |>
  summarize(km = sum(len_m) / 1000) |>
  arrange(desc(km)) |>
  collect()
#> year_key                     km
#> 2006|2011|2016|2021       4748.
#> 1996|2006|2011|2016|2021  4634.
#> 2016|2021                 1087.
#> 2006|2011                  579.
#> ...
```

`year_key` is the set of years as a string, for grouping; `years` is the same
set as a list column, for `list_contains(years, 1996)`; `n_years`,
`first_year` and `last_year` fall out of it. Roads that have gone are
`last_year < 2021`; roads that are new are `first_year > 1996`.

Three things the design commits to.

**Newer geometry wins.** Geocoding accuracy improves across the series, so a
segment's geometry is always cut from the newest year it appears in --
`last_year == spine_vintage` holds for every row. Older vintages contribute
geometry only where no newer one covers them, which is exactly the set of roads
that have since been retired.

**Segments are cut where the years disagree.** The vintages do not agree on
where one arc ends and the next begins -- the same Calgary extent holds 27,462
arcs in 1996, 30,759 in 2006 and 58,791 in 2021. Rather than trying to match
whole arc to whole arc, which succeeds for barely a third of them, arcs are cut
at every point where any vintage's coverage changes, so a segment is uniform in
its year membership over its whole length.

**Matching is calibrated, not assumed.** `temporal_network_calibration()`
reports what the build measured before it matched anything: how far same-named
arcs sit from each other in each vintage pair, and the rate at which a given
tolerance starts matching a road to its neighbour instead. `tolerance =`
overrides it. `get_temporal_network_sources()` is the crosswalk -- one row per
segment per year, naming the source arc, the distance, and which rule matched
it -- so nothing about the matching has to be taken on trust.

Region identifiers are not stable through time either: Statistics Canada reuses
`CSDUID` codes across boundary revisions, so restricting to a region is done by
stamping one fixed polygon across every year, never by filtering the attribute.
`temporal_network_region_drift()` turns that into a result rather than a
caveat, reporting every stretch of road that changed census subdivision without
moving -- for Calgary 2011-2021 it recovers the annexation of 54.7 km of road
into Airdrie, along with smaller transfers into Calgary, Chestermere and
Cochrane.

The years are yours to pick: any two or more vintages in any spacing, `NULL` for
everything the cache already holds, and a second build under another name can
use a different set. `vignette("canstreet-temporal")` works the Calgary pilot
through end to end.

`within = NULL` builds the whole country, but region-scoped builds are the
supported scale for now: a national two-vintage build spilled over 32 GB of
temporary storage in the coverage pass on the machine this was developed on,
and did not finish. A CMA-sized region takes about 20 seconds for five
vintages.

## Data and coverage

| Vintages | Product | Coverage | Source |
|---|---|---|---|
| 1976, 1981 | Area Master File | British Columbia, urban | Abacus Data Network (UBC) |
| 1991, 1996 | Street Network File | Large urban centres | Abacus Data Network (UBC) |
| 2001 | Road Network File (92F0157GIE) | National | Statistics Canada |
| 2005-2025 | Road Network File (92-500-X) | National | Statistics Canada |

Statistics Canada's [Census Dictionary entry for the Road Network
File](https://www12.statcan.gc.ca/census-recensement/2011/ref/dict/geo041-eng.cfm)
gives the official account of the series and its coverage by census year: road
network files covering the entire country for 2011, 2006 and 2001; street
network files covering large urban centres for 1996; and area master files, also
urban only, for 1991 and every census back to 1971. Of those area master files,
the 1976 and 1981 British Columbia deposits are here; no digital file for 1971
or 1986 could be located in any accessible repository. The package's source
manifest is a plain data table, so further years and provinces can be added
without code changes.

The area master files are not a GIS format and no GDAL driver reads them: they
are mainframe flat files, one fixed-width record per line, describing each
street as a chain of nodes in NAD27 UTM. `read_amf()` parses either release --
1976 writes its coordinates as text, 1981 is an EBCDIC original whose
coordinates are packed decimal -- into block-face segments carrying the street
name, the feature class and the civic address range on each side. They import
like any other vintage, and their geometry stands up: 89-92% of their road
length has a 1991 Street Network File arc within 20 m of its midpoint, and
95-96% within 40 m.

Two caveats from that page carry straight into any analysis of change over time.
Statistics Canada states that **"topological accuracy takes precedence over
absolute positional accuracy"**: the files are built for census enumeration, so
the relative position of features is maintained and their absolute position is
not. That is why matching across years has to be tolerant rather than exact, and
why the tolerance is measured per vintage pair rather than assumed. And the
files are **not routable** -- there is no one-way, turn-restriction or
dead-end information, and address ranges may be imputed rather than observed.

One thing the dictionary does not say, established here by reading the files:
the early vintages carry more than roads. The area master files and the 1991 and
1996 Street Network Files are a full topographic base rather than a road
network -- watercourses,
railways, hydro lines, census-boundary arcs and the outlines of parks, golf
courses and airports are all carried as arcs, about a third of the 1996 file's
160,000 km and a comparable share of each area master file: shorelines,
municipal boundaries and creeks account for 2,283 of 1976's 8,857 km and 5,011
of 1981's 15,508 km. 2001 ships as an ArcInfo coverage whose arc layer carries the
boundary topology of the census geography alongside the network, another 388,345
km, every provincial border and coastline among it. `get_road_network()` returns
all of it as it comes; `build_temporal_network()` drops it by default, because
the Road Network Files from 2005 on contain none of it and leaving it in reports
every river, rail line and provincial boundary as a road that has since been
removed.

Segments from every vintage are harmonized onto one schema -- see
`canstreet_schema()` -- and all geometry is stored in EPSG:3347 (NAD83 /
Statistics Canada Lambert), so `len_m` and any distance computed from the
geometry are in metres regardless of the vintage's own coordinate system.

The two coded columns, `class` and `rank`, are stored as labels rather than as
the codes the source files carry, so a road classed `23` comes back as `Local`.
Statistics Canada publishes the vocabulary once per census year and it genuinely
changes between them -- 2016 defines class `95` as a second "Unknown", 2021
retires it and adds `87` for winter roads, 2001 uses a numeric vocabulary with
no code in common with 2011 onward, and the 1991 and 1996 Street Network Files
classify *features* rather than roads -- so the label a code gets depends on the
vintage it came from. `canstreet_domains()` returns the tables, which is what
you need to go back from a label to a code. The vocabularies are read from
primary sources: the reference guide shipped inside each Road Network File
archive, the Street Network File User Guide from the Abacus deposit, and the
2021 Census attribute domain values page. Where no vocabulary was ever
published -- 2005 to 2010, and the two area master files -- the codes are kept
as they are.

## Attribution

Source data are &copy; Statistics Canada, distributed under the
[Statistics Canada Open Licence](https://www.statcan.gc.ca/en/reference/licence).
Cite the product and reference year in anything you publish from it.
