# Small shared utilities. The unzip and download helpers are adapted from
# `canpumf`, where each fallback was added in response to a real Statistics
# Canada archive that the simpler path could not open.

`%||%` <- function(x, y) if (is.null(x)) y else x

# Resolve and create the cache directory.
cs_cache_dir <- function(cache_path, ...) {
  path <- file.path(cache_path, ...)
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  path
}

cs_message <- function(quiet, ...) {
  if (!isTRUE(quiet)) message(...)
  invisible(NULL)
}

# Signal a graceful, classed network error. Callers that front a download catch
# `canstreet_network_error` and degrade to an informative message rather than a
# hard error -- a package that uses Internet resources must not fail a check
# run just because a host is unreachable (CRAN policy).
cs_network_error <- function(message) {
  structure(
    class = c("canstreet_network_error", "error", "condition"),
    list(message = message, call = NULL))
}

# download.file() wrapper that converts any failure -- unreachable host, HTTP
# error, or a truncated/empty result -- into a canstreet_network_error.
cs_download <- function(url, destfile, quiet = FALSE, ...) {
  # These archives run to 350 MB; the 60-second default aborts most of them.
  old <- options(timeout = max(3600, getOption("timeout")))
  on.exit(options(old), add = TRUE)

  status <- tryCatch(
    utils::download.file(url, destfile, mode = "wb", quiet = quiet, ...),
    error = function(e) 1L)
  ok <- identical(as.integer(status), 0L) &&
    file.exists(destfile) && file.info(destfile)$size > 0
  if (!ok) {
    if (file.exists(destfile)) unlink(destfile)
    stop(cs_network_error(paste0(
      "Could not download '", url, "'. The server may be down or the file may ",
      "have moved -- try again later.")))
  }
  invisible(destfile)
}

# Statistics Canada answers a request for a release it does not have with a 302
# to a landing page served as `200 OK, text/html` -- a soft 404. A HEAD request
# therefore has to be judged on content type and length, not on status code.
cs_headers_are_an_archive <- function(headers) {
  h <- curl::parse_headers_list(headers)
  type <- tolower(h[["content-type"]] %||% "")
  size <- suppressWarnings(as.numeric(h[["content-length"]] %||% NA))
  is_archive <- grepl("zip|octet-stream|x-msdownload", type)
  is_archive && (is.na(size) || size > 1e6)
}

# TRUE if `url` looks like it really serves an archive.
cs_url_is_available <- function(url) {
  res <- tryCatch(
    curl::curl_fetch_memory(url, curl::new_handle(nobody = TRUE,
                                                  followlocation = TRUE)),
    error = function(e) NULL)
  if (is.null(res)) return(FALSE)
  cs_headers_are_an_archive(rawToChar(res$headers))
}

# Low-level extractor: zip::unzip() first (locale-agnostic, handles the
# CP437/Latin-1 entry names StatCan ships without the UTF-8 flag), then ditto
# on macOS, then system unzip, then utils::unzip. Windows self-extracting
# archives are zips with an executable stub prepended and open here unchanged.
.unzip_impl <- function(path, exdir) {
  if (requireNamespace("zip", quietly = TRUE) &&
      tryCatch({ zip::unzip(path, exdir = exdir); TRUE },
               error = function(e) FALSE))
    return(invisible(NULL))

  if (Sys.info()[["sysname"]] == "Darwin") {
    exit <- system2("ditto",
                    c("-x", "-k", "--sequesterRsrc", "--rsrc",
                      shQuote(path), shQuote(exdir)))
    if (exit != 0L) {
      exit2 <- system2("unzip", c("-o", shQuote(path), "-d", shQuote(exdir)),
                       stdout = FALSE, stderr = FALSE)
      if (exit2 != 0L) utils::unzip(path, exdir = exdir)
    }
  } else {
    exit <- suppressWarnings(
      system2("unzip", c("-o", shQuote(path), "-d", shQuote(exdir)),
              stdout = FALSE, stderr = FALSE))
    if (!identical(as.integer(exit), 0L)) utils::unzip(path, exdir = exdir)
  }
  invisible(NULL)
}

# Extract `path` into `exdir`, working around archives whose single top-level
# directory is named after the archive itself: when the zip lives inside exdir,
# extracting would need a directory at the same path as the file. Extract to a
# temp sibling, strip the extension from the colliding directory, then move in.
robust_unzip <- function(path, exdir) {
  zip_name <- basename(path)

  top_entries <- tryCatch(utils::unzip(path, list = TRUE)$Name,
                          error = function(e) character(0L))
  # useBytes = TRUE matches the ASCII "/" without attempting an encoding
  # translation that would warn on CP1252 entry names.
  top_dirs <- unique(sub("/.*", "/",
                         grep("/", top_entries, value = TRUE, fixed = TRUE,
                              useBytes = TRUE),
                         useBytes = TRUE))
  has_collision <- paste0(zip_name, "/") %in% top_dirs

  if (has_collision) {
    tmp_dir <- paste0(exdir, "_unzip_tmp")
    dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
    on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

    .unzip_impl(path, tmp_dir)

    safe_name <- sub("\\.(zip|exe)$", "", zip_name, ignore.case = TRUE)
    from_col <- file.path(tmp_dir, zip_name)
    if (file.exists(from_col))
      file.rename(from_col, file.path(tmp_dir, safe_name))

    for (item in list.files(tmp_dir, all.files = FALSE)) {
      dest <- file.path(exdir, item)
      if (!file.exists(dest))
        file.rename(file.path(tmp_dir, item), dest)
    }
  } else {
    .unzip_impl(path, exdir)
  }
  invisible(NULL)
}

# Convert an ArcInfo interchange coverage to a shapefile beside it.
#
# 2001 is the only vintage that arrives this way, and reading it directly is
# not an option: DuckDB's `ST_Read` over GDAL's AVCE00 driver scanned about
# 230 rows a second, which is over two hours for the file's 2,053,112 arcs,
# where `ogr2ogr` writes the whole thing as a shapefile in ninety seconds.
#
# A coverage names its layers by geometry -- `ARC` is the network, `PAL`,
# `CNT` and `LAB` are the polygon side -- so the layer is selected explicitly;
# without it all four would be written.
#
# `ENCODING=` (empty) is what makes the accents survive. The coverage's `.dbf`
# is Latin-1 (60,918 bytes above 0x7F, `0xE9` for the acute e of "Vérendrye"
# most of all), and GDAL passes those bytes through unrecoded while believing
# them to be UTF-8. Writing an empty layer encoding tells it to keep them as
# they are and write no `.cpg`, which leaves exactly the file every other RNF
# vintage ships: a Latin-1 `.dbf` with no declared encoding, read back with
# the `ENCODING=ISO-8859-1` that `cs_st_read_sql()` already applies. Letting
# GDAL write its default `.cpg` instead would label the bytes UTF-8 and the
# first accented street name would abort the scan.
cs_coverage_to_shapefile <- function(path) {
  out <- paste0(tools::file_path_sans_ext(path), "_arc.shp")
  if (file.exists(out)) return(out)
  # A shapefile field name is ten characters, so GDAL warns thirteen times
  # about truncating this coverage's -- `ADDR_FM_LEFT` to `ADDR_FM_LE` and so
  # on. That truncation is not a loss, it is the point: it lands the columns on
  # the same ten-character spellings every other vintage ships and the alias
  # table already resolves. Only these are muffled; any other GDAL warning
  # still reaches the caller.
  withCallingHandlers(
    sf::gdal_utils("vectortranslate", source = path, destination = out,
                   options = c("-f", "ESRI Shapefile",
                               "-sql", "SELECT * FROM ARC",
                               "-lco", "ENCODING=")),
    warning = function(w) {
      if (grepl("[Nn]ormalized/laundered field name", conditionMessage(w))) {
        invokeRestart("muffleWarning")
      }
    })
  if (!file.exists(out)) {
    stop("Could not convert the ArcInfo coverage '", basename(path),
         "' to a shapefile.", call. = FALSE)
  }
  # GDAL writes a zero-byte .cpg for an empty ENCODING; left in place it is an
  # ambiguous declaration where none is wanted.
  cpg <- paste0(tools::file_path_sans_ext(out), ".cpg")
  if (file.exists(cpg) && file.size(cpg) == 0) unlink(cpg)
  out
}

# Locate the road/street line layer inside an extracted archive. Several
# vintages ship block or hydrography polygons alongside the streets, so the
# shapefile is chosen on geometry type rather than on position or size.
#
# 2001 is the exception: Statistics Canada ships it as an ArcInfo interchange
# coverage rather than a shapefile. It is converted to one here, so that
# everything downstream sees the same shape of file every other vintage has.
cs_resolve_line_source <- function(dir) {
  e00 <- list.files(dir, pattern = "\\.e00$", recursive = TRUE,
                    full.names = TRUE, ignore.case = TRUE)
  if (length(e00)) {
    return(vapply(e00, cs_coverage_to_shapefile, character(1),
                  USE.NAMES = FALSE))
  }

  shps <- list.files(dir, pattern = "\\.shp$", recursive = TRUE,
                     full.names = TRUE, ignore.case = TRUE)
  if (!length(shps)) {
    stop("No shapefile or ArcInfo coverage found in '", dir, "'.",
         call. = FALSE)
  }
  if (length(shps) == 1L) return(shps)

  is_line <- vapply(shps, function(p) {
    g <- tryCatch(as.character(sf::st_geometry_type(sf::st_read(
      p, quiet = TRUE, query = paste0(
        "SELECT * FROM \"", tools::file_path_sans_ext(basename(p)),
        "\" LIMIT 1")))),
      error = function(e) NA_character_)
    isTRUE(grepl("LINE", g[1]))
  }, logical(1))

  if (!any(is_line)) {
    stop("No line-geometry shapefile found in '", dir, "'.", call. = FALSE)
  }
  shps[is_line]
}

utils::globalVariables(c("vintage", "geom", "n",
                         # temporal-network columns used in dplyr verbs
                         "len_m", "years", "year_key", "n_years",
                         "first_year", "last_year", "spine_vintage",
                         "name_fold", "seg_id", "lo", "hi", "covered"))
