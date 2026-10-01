# Skip when the DuckDB spatial extension cannot be installed or loaded --
# it is downloaded on first use, so a sandboxed or offline machine has none.
skip_if_no_duckdb_spatial <- function() {
  ok <- tryCatch({
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    cs_load_spatial(con)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) testthat::skip("DuckDB spatial extension unavailable")
}

# An isolated cache directory that is removed when the calling test ends.
local_cache <- function(env = parent.frame()) {
  path <- withr::local_tempdir(.local_envir = env)
  withr::defer(canstreet_disconnect(path), envir = env)
  path
}

# Write a small shapefile standing in for one vintage's source file. `fields`
# is a named list of attribute columns, so a test can spell the column names
# the way any given vintage does.
write_fixture_shp <- function(dir, layer, fields, crs = 4269, n = NULL) {
  n <- n %||% length(fields[[1]])
  geoms <- sf::st_sfc(lapply(seq_len(n), function(i) {
    x <- -123.1 + i / 1000
    sf::st_linestring(matrix(c(x, 49.2, x + 0.001, 49.201), ncol = 2,
                             byrow = TRUE))
  }), crs = crs)
  obj <- sf::st_sf(as.data.frame(fields, stringsAsFactors = FALSE),
                   geometry = geoms)
  path <- file.path(dir, paste0(layer, ".shp"))
  suppressWarnings(sf::st_write(obj, path, quiet = TRUE, delete_dsn = TRUE))
  path
}

# Write a small MapInfo interchange pair standing in for 2001, the one vintage
# that does not arrive as a shapefile. A MapInfo column name is not clipped to
# ten characters, so this is also the only fixture that can spell the address
# columns the way that release does. `geometry = "polygon"` writes the block
# layer that ships beside the roads, which the resolver has to reject.
write_fixture_mif <- function(dir, layer, fields, crs = 4269,
                              geometry = c("line", "polygon")) {
  geometry <- match.arg(geometry)
  n <- length(fields[[1]])
  geoms <- sf::st_sfc(lapply(seq_len(n), function(i) {
    x <- -123.1 + i / 1000
    if (geometry == "line") {
      sf::st_linestring(matrix(c(x, 49.2, x + 0.001, 49.201),
                               ncol = 2, byrow = TRUE))
    } else {
      sf::st_polygon(list(matrix(
        c(x, 49.2, x + 0.001, 49.2, x + 0.001, 49.201, x, 49.201, x, 49.2),
        ncol = 2, byrow = TRUE)))
    }
  }), crs = crs)
  obj <- sf::st_sf(as.data.frame(fields, stringsAsFactors = FALSE),
                   geometry = geoms)
  path <- file.path(dir, paste0(layer, ".MIF"))
  suppressWarnings(sf::st_write(obj, path, driver = "MapInfo File",
                                quiet = TRUE, delete_dsn = TRUE))
  # GDAL's MapInfo writer lower-cases the extension; the released files are
  # upper-case. Report what is actually on disk, so a test can compare paths.
  list.files(dir, pattern = paste0("^", layer, "\\.mif$"),
             full.names = TRUE, ignore.case = TRUE)[1]
}

# Import a fixture shapefile into `table` exactly as cs_import_vintage would.
import_fixture <- function(con, path, vintage, table = "fixture") {
  src <- cs_source(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  DBI::dbExecute(con, cs_harmonize_sql(con, path, src, table))
  cs_normalize_address_ranges(con, table)
  tibble::as_tibble(DBI::dbGetQuery(
    con, paste0("SELECT * EXCLUDE (geom) FROM ",
                DBI::dbQuoteIdentifier(con, table), " ORDER BY source_id")))
}

# An in-memory DuckDB with the spatial extension loaded.
local_spatial_con <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  cs_load_spatial(con)
  con
}

# A cache directory holding a database with one fixture vintage imported, so
# the api-level functions can be exercised without touching the network.
local_fixture_db <- function(vintage = 2011, n = 5, env = parent.frame()) {
  cache <- local_cache(env)
  dir <- withr::local_tempdir(.local_envir = env)
  con <- cs_connect(cache, read_only = FALSE)
  cs_meta_init(con)

  path <- write_fixture_shp(dir, "fx", list(
    NGD_UID = as.character(seq_len(n)),
    NAME = paste0("Street", seq_len(n)),
    TYPE = rep("ST", n),
    AFL_VAL = seq_len(n) * 100L,
    ATL_VAL = seq_len(n) * 100L + 98L,
    CSDNAME_L = rep("Vancouver", n)), crs = cs_source(vintage)$crs)

  table <- cs_table_name(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  DBI::dbExecute(con, cs_harmonize_sql(con, path, cs_source(vintage), table))
  cs_meta_write(con, vintage, list(schema_version = cs_schema_version(),
                                   crs = cs_storage_crs(), n_segments = n,
                                   n_archives = 1L,
                                   imported_at = format(Sys.time()),
                                   package_version = "0.0.0.9000"))
  cs_rebuild_segments_view(con)
  canstreet_disconnect(cache)
  cache
}

# Insert arcs straight into a vintage table, bypassing the shapefile import.
# The temporal network reads only the vintage tables, so a fixture written this
# way exercises everything under test while letting a test state its geometry in
# exact metres -- which is what makes an 8 m offset assertable as an 8 m offset.
# Coordinates are treated as EPSG:3347, but nothing in the matching is
# projection-aware, so any local metric frame does.
write_fixture_arcs <- function(con, vintage, arcs) {
  table <- cs_table_name(vintage)
  DBI::dbExecute(con, cs_create_table_sql(con, table))
  values <- vapply(seq_len(nrow(arcs)), function(i) {
    paste0("(", vintage, ", 'fixture', ",
           DBI::dbQuoteString(con, arcs$source_id[i]), ", ",
           DBI::dbQuoteString(con, arcs$name[i]), ", ",
           DBI::dbQuoteString(con, arcs$class[i] %||% NA_character_), ", ",
           "st_length(st_geomfromtext(",
           DBI::dbQuoteString(con, arcs$wkt[i]), ")), st_geomfromtext(",
           DBI::dbQuoteString(con, arcs$wkt[i]), "))")
  }, character(1))
  DBI::dbExecute(con, paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(con, table),
    " (vintage, source_file, source_id, name, class, len_m, geom) VALUES\n",
    paste(values, collapse = ",\n"), ";"))

  # Register the fixture the way an import would, so anything that asks the
  # database what it holds -- `cs_db_vintages()`, `list_canstreet_cache()`, a
  # build with `vintages = NULL` -- sees it.
  cs_meta_write(con, vintage, list(
    schema_version = as.character(cs_schema_version()),
    crs = cs_storage_crs(),
    source_crs = cs_storage_crs(),
    product = "fixture",
    host = "fixture",
    coverage = "fixture",
    n_segments = as.character(nrow(arcs)),
    n_archives = "0",
    package_version = as.character(utils::packageVersion("canstreet")),
    imported_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ))
  cs_rebuild_segments_view(con)
  invisible(table)
}

arc <- function(source_id, name, wkt, class = NA_character_) {
  data.frame(source_id = source_id, name = name, wkt = wkt, class = class,
             stringsAsFactors = FALSE)
}

# A horizontal segment of `len` metres at height `y`, as WKT.
fx_line <- function(y, x0 = 0, len = 200) {
  paste0("LINESTRING(", x0, " ", y, ", ", x0 + len, " ", y, ")")
}

# A 12-point arc bowing `rise` metres off the straight line from (0, y) to
# (len, y) -- the coarse-chord-versus-fine-curve case that the same-name rescue
# exists for.
fx_bow <- function(y, len = 1000, rise = 90, n = 12) {
  x <- seq(0, len, length.out = n)
  yy <- y + rise * (1 - (2 * x / len - 1)^2)
  paste0("LINESTRING(", paste0(round(x, 3), " ", round(yy, 3),
                               collapse = ", "), ")")
}

# Two vintages whose correct temporal answer is known by construction. See
# test-tnet.R for what each row is there to prove.
write_fixture_pair <- function(con) {
  old <- rbind(
    arc("o1", "ALPHA",   fx_line(0)),      # identical in both
    arc("o2", "BETA",    fx_line(100)),    # 8 m from its 2021 counterpart
    arc("o3", "GAMMA",   fx_line(200)),    # 60 m away, different name: retired
    arc("o4", "EPSILON", fx_line(300)),    # one arc that 2021 splits in two
    arc("o5", "ETA",     fx_line(500)),    # present only in 1996
    arc("o6", "THETA",   fx_line(600, len = 1000)),  # coarse chord
    arc("o7", "SOME RIVER", fx_line(800), class = "WCR"),  # not a road at all
    arc("o8", "OLD MAIN", fx_line(900)))   # the same road, renamed by 2021
  new <- rbind(
    arc("n1", "ALPHA",   fx_line(0)),
    arc("n2", "BETA",    fx_line(108)),
    arc("n3", "DELTA",   fx_line(260)),
    arc("n4", "EPSILON", fx_line(300, len = 100)),
    arc("n5", "EPSILON", fx_line(300, x0 = 100, len = 100)),
    arc("n6", "ZETA",    fx_line(400)),    # present only in 2021
    arc("n7", "THETA",   fx_bow(600)),     # the same road, finely digitized
    arc("n8", "NEW MAIN", fx_line(908)))   # 8 m from OLD MAIN, renamed
  write_fixture_arcs(con, 1996, old)
  write_fixture_arcs(con, 2021, new)
  invisible(c(1996L, 2021L))
}

# A grid of `n` named streets, each offset by `offset` metres between the two
# vintages, plus an optional uniform `shift` applied to every 2021 arc. Enough
# pairs for cs_calibrate_tolerance() to have something to measure.
write_fixture_grid <- function(con, n = 60, offset = 8, shift = c(0, 0)) {
  nm <- sprintf("STREET %03d", seq_len(n))
  old <- do.call(rbind, lapply(seq_len(n), function(i)
    arc(paste0("o", i), nm[i], fx_line(i * 100))))
  new <- do.call(rbind, lapply(seq_len(n), function(i)
    arc(paste0("n", i), nm[i],
        paste0("LINESTRING(", shift[1], " ", i * 100 + offset + shift[2],
               ", ", 200 + shift[1], " ", i * 100 + offset + shift[2], ")"))))
  write_fixture_arcs(con, 1996, old)
  write_fixture_arcs(con, 2021, new)
  invisible(c(1996L, 2021L))
}


# --- Area Master File fixtures -----------------------------------------------

# One AMF record as a vector of byte values, built by placing fields at their
# 1-based columns; everything else stays blank. A field is either a string or a
# vector of byte values already -- a packed coordinate, or the binary filler.
amf_rec <- function(width, ...) {
  r <- rep(0x20L, width)
  for (f in list(...)) {
    v <- f[[2]]
    if (is.character(v)) v <- utf8ToInt(v)
    if (length(v)) r[f[[1]] + seq_along(v) - 1L] <- v
  }
  r
}

# Encode a coordinate the way the packed transcription does: seven digits
# packed two to the byte with a sign nibble, as EBCDIC, then mapped back into
# the Latin-1 bytes the deposit ships. `cs_amf_ebcdic_table()` is the forward
# map, so the fixture inverts it rather than carrying a second table.
amf_pack <- function(v) {
  d <- as.integer(strsplit(sprintf("%07d", v), "")[[1]])
  eb <- c(d[1] * 16L + d[2], d[3] * 16L + d[4],
          d[5] * 16L + d[6], d[7] * 16L + 12L)
  match(eb, as.integer(cs_amf_ebcdic_table())) - 1L
}

# The record constructors of one transcription, written the way the files of
# that transcription write them: the national `wide` files left-justify the
# feature code and the zone, put a count where a municipality record's feature
# code would be, write a missing coordinate as zeros and end their lines CR LF;
# the two Abacus deposits right-justify, leave the count out and end in LF.
amf_writer <- function(layout, cma = "5937") {
  lay <- cs_amf_layout(layout)
  w <- lay$width
  wide <- identical(layout, "wide")
  coord <- switch(layout, packed = amf_pack,
                  text = function(v) sprintf("%07d", v),
                  wide = function(v) sprintf("%08d", v))
  # A coordinate that is not there is a run of EBCDIC blanks: in the packed
  # file those are the bytes themselves, in the seven-digit one the digits
  # they unpack to, and in the eight-digit one zeros.
  blank <- switch(layout, packed = rep(0x20L, 4L), text = "4040404",
                  wide = "00000000")
  fcode <- function(f) sprintf(if (wide) "%-6d" else "%6d", f)
  filler <- list(22L, c(0L, 0L, 0L))

  heading <- function(zone, name) {
    if (wide) {
      amf_rec(w, list(1L, cma), list(9L, "000"), list(22L, "06"),
              list(36L, sprintf("%-3d", zone)), list(39L, name))
    } else {
      amf_rec(w, list(1L, cma), list(15L, "000"), list(22L, "01"),
              list(36L, sprintf("%3d", zone)), list(39L, name))
    }
  }
  muni <- function(area, name, count = "0") {
    if (wide) {
      amf_rec(w, list(1L, cma), list(5L, area), list(9L, count),
              list(15L, "001"), list(18L, "00"), list(22L, name),
              list(42L, "0"))
    } else {
      amf_rec(w, list(1L, cma), list(5L, area), list(15L, "001"),
              list(20L, "00"), list(22L, name))
    }
  }
  header <- function(area, feature, name, type = "ST", dir = "") {
    amf_rec(w, list(1L, cma), list(5L, area), list(9L, fcode(feature)),
            list(15L, "000"), filler, list(25L, "0"), list(27L, name),
            list(47L, type), list(49L, sprintf("%2s", dir)))
  }
  node <- function(area, feature, seq_no, x, y, chain = " ", class = "",
                   node = "0001", to_l = "", to_r = "",
                   from_l = "", from_r = "", xref = 18700L, rec_cma = cma) {
    a <- lay$addr
    r <- lay$ref
    rw <- lay$coord_width
    # Every node in the real files carries two block reference points and a
    # cross-street reference, which is what makes the records reach full width.
    ref <- if (is.na(x)) rep(list(blank), 4L) else
      lapply(c(x - 40L, y - 40L, x + 40L, y + 40L), coord)
    amf_rec(w, list(1L, rec_cma), list(5L, area), list(9L, fcode(feature)),
            list(15L, sprintf("%03d", seq_no)), list(18L, class),
            list(20L, "02"), filler, list(25L, "0"),
            list(27L, node), list(31L, chain),
            list(lay$x[1], if (is.na(x)) blank else coord(x)),
            list(lay$y[1], if (is.na(y)) blank else coord(y)),
            list(a, to_l), list(a + 5L, to_r),
            list(a + 10L, from_l), list(a + 15L, from_r),
            list(r, ref[[1]]), list(r + rw, ref[[2]]),
            list(r + 2L * rw, ref[[3]]), list(r + 3L * rw, ref[[4]]),
            list(lay$xr_area[1], area),
            list(lay$xr_id[1], paste0(fcode(xref), "010")),
            list(lay$xr_name[1], "CROSS"), list(lay$xr_type[1], "ST"))
  }
  write <- function(recs, path) {
    con <- file(path, "wb")
    on.exit(close(con), add = TRUE)
    eol <- if (wide) as.raw(c(0x0d, 0x0a)) else as.raw(0x0a)
    for (r in recs) {
      # The real files strip trailing blanks, so the fixture does too -- which
      # is what puts the reader's padding under test.
      keep <- rev(cumsum(rev(r != 0x20L))) > 0L
      writeBin(c(as.raw(r[keep]), eol), con)
    }
    path
  }
  list(layout = lay, heading = heading, muni = muni, header = header,
       node = node, write = write)
}

# The same logical file in any of the three transcriptions: they must parse to
# the identical answer. See test-amf.R for what each piece is there to prove.
write_fixture_amf <- function(dir, layout = "wide",
                              name = paste0(layout, "_fx.data")) {
  w <- amf_writer(layout)
  node <- w$node

  recs <- list(
    w$heading(10L, "SHEET ONE"),
    w$muni("1522", "VANCOUVER"),

    # A three-node chain: two segments, each taking its `from` addresses from
    # the node it starts at and its `to` addresses from the node it ends at.
    w$header("1522", 1200L, "MAIN"),
    node("1522", 1200L, 10L, 425833L, 5458561L, chain = "B", node = "0011",
         from_l = "  100", from_r = "  101"),
    node("1522", 1200L, 20L, 425933L, 5458561L, node = "0012",
         to_l = "  198", to_r = "  199", from_l = "  200", from_r = "  201"),
    node("1522", 1200L, 30L, 426033L, 5458561L, chain = "E", node = "0013",
         to_l = "  298", to_r = "  299"),

    # Filed out of sequence and split into two chains: sorting must restore the
    # order, and no segment may bridge the `E`/`B` break.
    w$header("1522", 1300L, "OAK", type = "AV"),
    node("1522", 1300L, 40L, 426333L, 5458761L, chain = "B", node = "0024"),
    node("1522", 1300L, 10L, 426133L, 5458561L, chain = "B", node = "0021"),
    node("1522", 1300L, 50L, 426433L, 5458761L, chain = "E", node = "0025"),
    node("1522", 1300L, 20L, 426233L, 5458561L, chain = "E", node = "0022"),

    # A node with no coordinate, and a coordinate repeated: neither can make a
    # segment.
    w$header("1522", 1400L, "CAMBIE"),
    node("1522", 1400L, 10L, 426533L, 5458561L, chain = "B", node = "0031"),
    node("1522", 1400L, 20L, NA, NA, node = "0032"),
    node("1522", 1400L, 30L, 426633L, 5458561L, node = "0033"),
    node("1522", 1400L, 40L, 426633L, 5458561L, chain = "E", node = "0034"),

    # Classed features: one road, one not. The highway's street type is an
    # ordinary one, the way the 1971 to 1981 files write it.
    w$header("1522", 1500L, "TRANS CANADA", type = "HY", dir = "E"),
    node("1522", 1500L, 10L, 426733L, 5458561L, chain = "B", class = "HN"),
    node("1522", 1500L, 20L, 426833L, 5458561L, chain = "E", class = "HN"),
    w$header("1522", 1600L, "BRUNETTE RIVER", type = ""),
    node("1522", 1600L, 10L, 426933L, 5458561L, chain = "B", class = "WN"),
    node("1522", 1600L, 20L, 427033L, 5458561L, chain = "E", class = "WN"),

    # A second heading reusing the municipality and feature numbers of the
    # first, which is what makes the heading part of the identifier.
    w$heading(10L, "SHEET TWO"),
    w$muni("1522", "BURNABY"),
    w$header("1522", 1200L, "MAIN"),
    node("1522", 1200L, 10L, 427133L, 5458561L, chain = "B"),
    node("1522", 1200L, 20L, 427233L, 5458561L, chain = "E")
  )
  w$write(recs, file.path(dir, name))
}

# A national file the way the 1986 release classes it: the feature type and
# sub-type in the class field and the qualifier List A completes them with in
# the street-type field of the header.
write_fixture_amf_1986 <- function(dir, name = "DA.AM86.FIXTURE.TXT") {
  w <- amf_writer("wide")
  node <- w$node
  feat <- function(feature, name, type, class, x) {
    list(w$header("1522", feature, name, type = type),
         node("1522", feature, 10L, x, 5458561L, chain = "B", class = class),
         node("1522", feature, 20L, x + 100L, 5458561L, chain = "E",
              class = class))
  }
  recs <- c(
    list(w$heading(10L, "FIXTURE"), w$muni("1522", "VANCOUVER")),
    feat(1000L, "GRANVILLE", "ST", "", 425000L),     # an ordinary street
    feat(1100L, "TRANS CANADA", "MU", "HN", 425200L),  # Highway multiple
    feat(1200L, "KINGSWAY", "BV", "E", 425400L),     # addressable multiple
    feat(1300L, "HWY 403", "PR", "HN", 425600L),     # Highway proposed
    feat(1400L, "STILL CREEK", "CR", "WN", 425800L), # Creek
    feat(1500L, "SEAWALL", "TR", "FN", 426000L))     # Trail
  w$write(recs, file.path(dir, name))
}

# The archive a vintage is hosted as: the files at the top level and a
# `documentation` directory beside them. Written straight into the place
# `canstreet_download()` would put it, so an import finds it cached.
write_fixture_amf_zip <- function(cache, vintage, files) {
  stage <- withr::local_tempdir()
  file.copy(files, stage)
  dir.create(file.path(stage, "documentation"))
  writeLines("Not an Area Master File.",
             file.path(stage, "documentation", "README.txt"))
  dest <- file.path(cache, "downloads", vintage)
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  zipfile <- file.path(dest, basename(cs_source(vintage)$resource))
  zip::zip(zipfile, c(basename(files), "documentation"), root = stage)
  zipfile
}
