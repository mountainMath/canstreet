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

# Locate the road/street line layer inside an extracted archive. Several
# vintages ship block or hydrography polygons alongside the streets, so the
# shapefile is chosen on geometry type rather than on position or size.
cs_resolve_line_shapefile <- function(dir) {
  shps <- list.files(dir, pattern = "\\.shp$", recursive = TRUE,
                     full.names = TRUE, ignore.case = TRUE)
  if (!length(shps)) {
    stop("No shapefile found in '", dir, "'.", call. = FALSE)
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

utils::globalVariables(c("vintage", "geom", "n"))
