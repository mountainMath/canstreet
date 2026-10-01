# canstreet 0.0.1

First numbered release. The package downloads the historical Statistics Canada
road and street network files, harmonizes them into one DuckDB store, and
matches segments across years into a temporally unified network.

## Vintages

* 28 vintages on one schema, in one coordinate reference system (EPSG:3347, so
  lengths and distances are metres throughout): the Area Master Files of the
  1971, 1976, 1981 and 1986 censuses, the Street Network Files of 1991 and
  1996, and the Road Network Files of 2001 and 2005 to 2025.
  `list_road_network_vintages()` lists them.
* The Area Master Files are national: all 462 flat files Statistics Canada
  supplied for the four censuses, one per municipality. They were never
  published online and are hosted by MountainMath, one archive per census.
  During development 1976 and 1981 were read from two British Columbia extracts;
  a cache that holds those re-imports the two years on next use, and temporal
  network builds made over them are dropped and need rebuilding.
* The Street Network Files come from the Abacus Dataverse deposit and the Road
  Network Files from Statistics Canada directly.

## Reading the network

* `get_road_network()` downloads and imports a vintage on first use and returns
  a lazy table; `within` filters spatially through the store's index and
  `roads_only` keeps each vintage's own road classes.
  `collect_road_network()` brings a result into R as `sf`, and
  `export_road_network()` writes it to a file.
* `get_road_network_database()` takes the same arguments and returns where the
  data is instead -- the DuckDB file, the tables in it and the equivalent
  query -- for reading the store from another tool.
* `class` and `rank` carry the published labels of each vintage's own guide.
  `canstreet_domains()` returns the vocabularies, `canstreet_road_classes()`
  says which classes count as road in which vintage, and `canstreet_schema()`
  describes the harmonized columns.
* `read_amf()` reads a single Area Master File, as segments or as the node
  records the file stores, in any of its three transcriptions.
* `canstreet_download()` fetches a vintage's archives without importing them.

## Temporal network

* `build_temporal_network()` matches segments across the named vintages, with
  a positional tolerance calibrated per vintage, and writes one table in which
  each segment is tagged with the years it is present in.
  `get_temporal_network()` reads a build and `get_temporal_network_sources()`
  its crosswalk back to each vintage's own arcs, with the name and file each
  arc had.
* `temporal_network_calibration()` and `temporal_network_region_drift()` report
  how well the vintages of a build agree; `list_temporal_networks()` and
  `remove_temporal_network()` manage builds.

## Cache

* `set_canstreet_cache_path()` sets where archives and the database are kept,
  `list_canstreet_cache()` shows what has been imported, and
  `remove_canstreet_cache()` removes vintages. Source archives are kept, so the
  database can be rebuilt without downloading again.

## Known limitations

* Part of the name fields in the 1981 Area Master Files arrived overwritten:
  62,507 of that year's 529,158 segments have their geometry, type and
  direction but no name.
* The files are not routable networks, and address ranges are sparse outside
  the cities.
