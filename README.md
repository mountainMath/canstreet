
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
`remove_canstreet_cache()` to evict a vintage.

## Data and coverage

| Vintages | Product | Source |
|---|---|---|
| 1991, 1996 | Street Network File | Abacus Data Network (UBC) |
| 2001 | Road Network File (92F0157GIE) | Abacus Data Network (UBC) |
| 2005-2025 | Road Network File (92-500-X) | Statistics Canada |

The 1991 and 1996 Street Network Files cover **urban areas only**; every vintage
from 2001 on is national. Vintages before 1991 are not yet available -- no
digital street network for 1971 or 1986 could be located in an accessible
repository, and the package's source manifest is a plain data table so earlier
years can be added without code changes.

Segments from every vintage are harmonized onto one schema -- see
`canstreet_schema()` -- and all geometry is stored in EPSG:3347 (NAD83 /
Statistics Canada Lambert), so `len_m` and any distance computed from the
geometry are in metres regardless of the vintage's own coordinate system.

Identifying common segments across years (item 2 above) and the temporally
unified network (item 3) are not implemented yet.

## Attribution

Source data are &copy; Statistics Canada, distributed under the
[Statistics Canada Open Licence](https://www.statcan.gc.ca/en/reference/licence).
Cite the product and reference year in anything you publish from it.
