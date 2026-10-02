
# canstreet

<!-- badges: start -->
<!-- badges: end -->

This package facilitates downloading and processing the historical Statistics Canada road/street network files. This enables understanding how the road network has evolved over time, which can be useful for a range of analysis applications, including in economics, urban planning, transportation studies, and historical research.

The package provides a uniform base for this to enable reproducible and collaborative work in this space.

## Functionality

The package provides basic functionality:

* Download and cache the historical road/street network files from Statistics Canada or from a custom hosted archive for older data that's only available via EFT.
* Filter the features into streets and roads, boundaries, and other features.
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
the environment variable directly, `canstreet_cache_path()` reports what is in
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

# First call downloads and imports, later calls are instant.
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
DuckDB, or `get_road_network_database()` to point another tool at the DuckDB
file itself, `list_canstreet_cache()` to see what the cache holds, and
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

`year_key` is the set of years as a string, for grouping, `years` is the same
set as a list column, for `list_contains(years, 1996)`, `n_years`,
`first_year` and `last_year` fall out of it. Roads that have gone are
`last_year < 2021`, roads that are new are `first_year > 1996`. New roads in the data can result from expansion of coverage as well as from new construction and this needs to get treated with appropriate caution when interpreting.

Region-scoped builds are the supported scale: `within = NULL` is accepted, but a
national build is resource intensive and not recommended. The years can be two or more vintages, or `NULL` for everything the cache holds.

More details on how this works and how to use it can be found in the function documentation
`?build_temporal_network` and these three vignettes:

- `vignette("canstreet-temporal")` -- a Calgary build explained end to end:
  calibration, the crosswalk, what disappeared, regions moving under the roads.
- `vignette("canstreet-vancouver")` -- eleven vintages over the Vancouver CMA,
  1971 to 2021, and what a segment's first year does and does not mean.
- `vignette("canstreet-renames")` -- reading street renamings off a finished
  build.

## Data and coverage

| Vintages | Product | Coverage | Source |
|---|---|---|---|
| 1971, 1976, 1981, 1986 | Area Master File | Large urban centres | MountainMath (the Statistics Canada files, hosted) |
| 1991, 1996 | Street Network File | Large urban centres | Abacus Data Network (UBC) |
| 2001 | Road Network File (92F0157GIE) | National | Statistics Canada |
| 2005-2025 | Road Network File (92-500-X) | National | Statistics Canada |

### Lineage

The three products in that table are one lineage, not three datasets. See Statistics
Canada's [2006 Census Dictionary note on the road network
file](https://www12.statcan.gc.ca/census-recensement/2006/ref/dict/geo041a-eng.cfm) and [Census Dictionary entry for the Road Network
File](https://www12.statcan.gc.ca/census-recensement/2011/ref/dict/geo041-eng.cfm) for details. Users should be aware of the changing coverage over time.

Two caveats from the dictionary entries carry straight into any analysis of change over
time. Statistics Canada states that **"topological accuracy takes precedence
over absolute positional accuracy"**: the files are built for census enumeration, so
the relative position of features is maintained and their absolute position is
not. That is why matching across years has to be tolerant rather than exact, and
why the tolerance is measured per vintage pair rather than assumed. And the
files are **not routable** -- there is no one-way, turn-restriction or
dead-end information, and address ranges may be imputed rather than observed.
Address ranges are also thin outside the cities even in the national era.
Statistics Canada says they are "generally available only in the large urban
centres of Canada", and the files bear it out: 74% of 2011 arcs inside a census
metropolitan area or agglomeration carry one against 43% outside (2016: 71% and
49%), and roughly three quarters of the country's road length is outside one.

Older Area Master Files come in legacy formats that are parsed with a custom reader via the `read_amf()` function that might be of use in other projects dealing with legacy spatial data.

There is a structural break in the provenance of the data, in [2001 StatCan reports](https://www12-2021.statcan.gc.ca/english/census01/products/reference/dict/geo041.htm) the Road Network Files "are derived from the
National Geographic Base (NGB)", and "much of the road network in the NGB was
realigned to match Natural Resources Canada's National Topographic Database", breaking from the 1996 Street Network Files and resulting in "improved geometry of RNFs, compared to SNFs" that can lead to sizable spatial shifts, e.g. in Vancouver every pre-2001 vintage puts 15th Avenue some 40 m north
of where 2001 and everything after it put the same street.


### Beyond roads

The early vintages carry more than roads. The area master files and the 1991
and 1996 Street Network Files are a full topographic base rather than a road
network: watercourses, railways, hydro lines, census-boundary arcs and the
outlines of parks, golf courses and airports are all carried as arcs, about a
third of the 1996 file's 160,000 km and a share of the area master files that
grows with each census: shorelines, creeks, railways and municipal boundaries
account for 6,035 of 1971's 31,882 km, 15,241 of 1976's 65,709 km, 19,663 of
1981's 80,100 km and 49,334 of 1986's 135,232 km. 2001 carries the boundary
topology of the census geography alongside the network, another 388,345 km, every
provincial border and coastline among it.

### Road classification

The files carry basic information on road class that gets more detailed with time and is not always directly comparable. Some vintages also contain data for "proposed", "planned" or "under construction" roads.

`canstreet_road_classes()` gives an overview of road classes, one row per class value per vintage, with its feature category, its build status, and whether it counts as a
road. `get_road_network(roads_only = TRUE)` applies it, and
`build_temporal_network()` applies it by default.

Passing
build statuses in place of `TRUE` keeps the non-road features out while letting
the not-yet-built roads back in:

```r
get_road_network(2016, roads_only = c("operational", "unknown", "planned"))
```

This can be useful for geocoding purposes, planned roads often carry address block data.

## Harmonization

Segments from every vintage are harmonized onto one schema (see
`canstreet_schema()`) and all geometry is stored in EPSG:3347 (NAD83 /
Statistics Canada Lambert), so `len_m` and any distance computed from the
geometry are in metres regardless of the vintage's own coordinate system.

The two coded columns, `class` and `rank`, are stored as labels rather than as
the codes the source files carry since codes are inconsistent over time.  `canstreet_domains()` provides a way to translate labels back to codes if needed.


## Attribution

Source data are &copy; Statistics Canada, distributed under the
[Statistics Canada Open Licence](https://www.statcan.gc.ca/en/reference/licence).
Cite the product and reference year in anything you publish from it.
