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
# to a landing page served as `200 OK, text/html` -- a soft 404. The probe
# therefore has to be judged on content type and length, not on status code.
cs_headers_are_an_archive <- function(headers) {
  h <- curl::parse_headers_list(headers)
  type <- tolower(h[["content-type"]] %||% "")
  # A ranged request is answered `206` with the slice's length in
  # `content-length` and the whole file's after the slash in `content-range`.
  # Take the latter wherever it is there, so the size test still sees the file
  # rather than the one byte asked for.
  size <- suppressWarnings(as.numeric(h[["content-length"]] %||% NA))
  range <- h[["content-range"]] %||% ""
  if (grepl("/[0-9]+$", range)) {
    size <- suppressWarnings(as.numeric(sub(".*/", "", range)))
  }
  is_archive <- grepl("zip|octet-stream|x-msdownload", type)
  is_archive && (is.na(size) || size > 1e6)
}

# TRUE if `url` looks like it really serves an archive.
#
# This asks for the first byte rather than sending a HEAD. Statistics Canada
# used to answer HEAD on these files and no longer does -- as of 2026-08-29 it
# 302s every one of them, the current release included, to its 404 page, so a
# HEAD probe reports every vintage as withdrawn and no download starts. A
# ranged GET is answered `206` with the real headers. `maxfilesize` bounds the
# case of a server that ignores `Range`: curl refuses a body it is told up
# front is larger, rather than pulling a 250 MB archive into memory to decide
# whether it exists.
cs_url_is_available <- function(url) {
  res <- tryCatch(
    curl::curl_fetch_memory(url, curl::new_handle(range = "0-0",
                                                  followlocation = TRUE,
                                                  maxfilesize = 1e6)),
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

e00_staging_dir <- "canstreet_staged"

# The Latin-1 supplement, folded to one ASCII byte each: 0x80 first, 0xFF
# last. An interchange file is ASCII text in fixed-width fields, so a byte
# above 0x7F cannot be recoded to UTF-8 -- widening it to two bytes would
# shift every field after it on that line -- and it cannot be left alone
# either, because the AVCE00 driver takes no open options at all, so no
# ENCODING reaches it and the raw byte lands in a DuckDB string that is not
# valid UTF-8. Folding to the unaccented base letter is the one repair that
# keeps a byte a byte. Across the whole 1991 and 1996 series it fires exactly
# once, on the non-breaking space in Toronto's `EA\xa096`.
cs_e00_ascii <- local({
  ascii <- rep(" ", 128L)                       # 0x80-0xFF, index is byte-127
  ascii[c(0xAA, 0xBA) - 127L] <- c("a", "o")    # the ordinal indicators
  ascii[(0xC0:0xFF) - 127L] <- strsplit(paste0(
    "AAAAAAAC", "EEEEIIII", "DNOOOOO ", "OUUUUYPs",
    "aaaaaaac", "eeeeiiii", "dnooooo ", "ouuuuypy"), "")[[1]]
  charToRaw(paste(ascii, collapse = ""))
})

# Fold every byte above 0x7F in a raw vector to its ASCII stand-in.
cs_e00_fold_bytes <- function(bytes) {
  hi <- bytes > as.raw(127L)
  if (!any(hi)) return(bytes)
  bytes[hi] <- cs_e00_ascii[as.integer(bytes[hi]) - 127L]
  bytes
}

# The volumes of one interchange coverage, in reading order.
#
# The 1991 Street Network Files ship as multi-volume sets -- `NET_TORO.E00`
# beside `.E01` ... `.E11` -- and the split is by byte count, not by section,
# so the volumes are a single file cut into pieces.
cs_e00_volumes <- function(path) {
  base <- tolower(tools::file_path_sans_ext(basename(path)))
  sibs <- list.files(dirname(path), full.names = TRUE)
  ext <- tolower(tools::file_ext(sibs))
  keep <- tolower(tools::file_path_sans_ext(basename(sibs))) == base &
    grepl("^e[0-9]{2}$", ext)
  sibs[keep][order(ext[keep])]
}

# Stage an ArcInfo interchange coverage for reading, and return the path.
#
# Two things have to happen before `ST_Read` sees one. GDAL opens the first
# volume of a multi-volume set alone and reports whatever part of the coverage
# it holds as if it were the whole -- 27,327 of Toronto's 82,725 arcs, with an
# extent to match, and no warning -- so the volumes are concatenated. And the
# high bytes are folded, for the reason `cs_e00_ascii` gives.
#
# Both are done in one streaming pass, in chunks, because a coverage can run
# to well over a gigabyte. The staged copy keeps the name of the first volume
# and goes in a subdirectory of its own, so that the `source_file` recorded
# for every segment is a file the deposit actually contains.
cs_e00_stage <- function(path) {
  dest <- file.path(dirname(path), e00_staging_dir)
  dir.create(dest, showWarnings = FALSE)
  out <- file.path(dest, basename(path))
  con <- file(out, "wb")
  on.exit(close(con), add = TRUE)

  for (vol in cs_e00_volumes(path)) {
    src <- file(vol, "rb")
    repeat {
      chunk <- readBin(src, "raw", 4e6L)
      if (!length(chunk)) break
      writeBin(cs_e00_fold_bytes(chunk), con)
    }
    close(src)
  }
  out
}

# Locate the road/street line layer inside an extracted archive. Several
# vintages ship block or hydrography polygons alongside the streets -- 2001's
# MapInfo release is an `ml` (line) pair beside an `mp` (polygon) one -- so the
# layer is chosen on geometry type rather than on position, size or name.
#
# Three container formats reach here. 1991 and 1996 are ArcInfo interchange
# coverages, whose `ARC` layer is the street network; 2001 is MapInfo
# interchange, a `.MIF` carrying the geometry with its `.MID` alongside
# carrying the attributes; every other vintage is a shapefile. DuckDB reads
# all three through the same `ST_Read`, so nothing downstream needs to know
# which it got -- only the coverage has to be staged first.
cs_resolve_line_source <- function(dir) {
  # Anything under the staging directory is a file this function wrote itself;
  # skipping it keeps a second call on the same directory idempotent.
  e00 <- list.files(dir, pattern = "\\.e00$", recursive = TRUE,
                    full.names = TRUE, ignore.case = TRUE)
  e00 <- e00[basename(dirname(e00)) != e00_staging_dir]
  if (length(e00)) {
    return(vapply(e00, cs_e00_stage, character(1), USE.NAMES = FALSE))
  }

  cand <- list.files(dir, pattern = "\\.(shp|mif)$", recursive = TRUE,
                     full.names = TRUE, ignore.case = TRUE)
  if (!length(cand)) {
    stop("No shapefile, MapInfo file or ArcInfo coverage found in '", dir,
         "'.", call. = FALSE)
  }
  if (length(cand) == 1L) return(cand)

  is_line <- vapply(cand, function(p) {
    g <- tryCatch(as.character(sf::st_geometry_type(sf::st_read(
      p, quiet = TRUE, query = paste0(
        "SELECT * FROM \"", tools::file_path_sans_ext(basename(p)),
        "\" LIMIT 1")))),
      error = function(e) NA_character_)
    isTRUE(grepl("LINE", g[1]))
  }, logical(1))

  if (!any(is_line)) {
    stop("No line-geometry layer found in '", dir, "'.", call. = FALSE)
  }
  cand[is_line]
}

utils::globalVariables(c("vintage", "geom", "n",
                         # temporal-network columns used in dplyr verbs
                         "len_m", "years", "year_key", "n_years",
                         "first_year", "last_year", "spine_vintage",
                         "name_fold", "seg_id", "lo", "hi", "covered"))
