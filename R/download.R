#' Download the source archives for a road network vintage
#'
#' Fetches the raw Statistics Canada archives for one vintage into the cache
#' and returns their paths. [get_road_network()] calls this for you; it is
#' exported so that a large download can be done deliberately, for instance to
#' warm a cache before working offline.
#'
#' The archives are kept after import (see [list_canstreet_cache()]), so the
#' database can always be rebuilt without re-downloading several gigabytes.
#'
#' Data are downloaded from Statistics Canada and from the Abacus Data Network
#' at the University of British Columbia, and are distributed under the
#' Statistics Canada Open Licence
#' (<https://www.statcan.gc.ca/en/reference/licence>).
#'
#' @param vintage Reference year of the network, e.g. `2021`. See
#'   [list_road_network_vintages()] for what is available.
#' @param refresh Re-download even when the archive is already cached.
#' @param quiet Suppress progress messages.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()],
#'   which reads the `CANSTREET_CACHE_PATH` environment variable, then the
#'   `canstreet.cache_path` option, then falls back to [tempdir()]. Set it once
#'   with [set_canstreet_cache_path()] to keep data between sessions.
#'
#' @return A [tibble::tibble()] with one row per downloaded archive:
#'   `vintage`, `filename`, `path`, `url` and `label` (the area the archive
#'   covers, for vintages that ship as per-area units).
#'
#' @examples
#' \dontrun{
#' # ~310 MB
#' canstreet_download(2021)
#' }
#' @export
canstreet_download <- function(vintage,
                               refresh = FALSE,
                               quiet = FALSE,
                               cache_path = canstreet_cache_path()) {
  src <- cs_source(vintage)
  dest_dir <- cs_cache_dir(cache_path, "downloads", as.character(src$vintage))

  todo <- switch(
    src$host,
    statcan = tibble::tibble(
      filename = basename(src$resource),
      url = src$resource,
      label = NA_character_,
      filesize = NA_real_
    ),
    abacus = {
      sel <- cs_abacus_select(src, cache_path, refresh = refresh, quiet = quiet)
      tibble::tibble(
        filename = sel$filename,
        url = cs_abacus_file_url(sel$id),
        label = sel$description,
        filesize = sel$filesize
      )
    },
    stop("Unknown host '", src$host, "' in the source manifest.", call. = FALSE)
  )

  todo$path <- file.path(dest_dir, todo$filename)
  have <- file.exists(todo$path) & !refresh

  if (any(!have)) cs_warn_cache_path_on_download(cache_path)

  if (any(!have)) {
    total <- sum(todo$filesize[!have], na.rm = TRUE)
    cs_message(quiet, "Downloading ", sum(!have), " archive",
               if (sum(!have) == 1L) "" else "s", " for vintage ",
               src$vintage,
               if (total > 0) paste0(" (~", round(total / 1e6), " MB)") else "",
               " ...")
  }

  # A missing StatCan release is served as a 302 to a landing page returned
  # with `200 OK, text/html`. download.file() would happily save that ~4 KB of
  # HTML as a .zip, and the failure would only surface much later as an
  # unreadable archive. Probe before committing to the download.
  if (identical(src$host, "statcan") && any(!have) &&
      !cs_url_is_available(src$resource)) {
    stop(cs_network_error(paste0(
      "Statistics Canada is not serving a road network file at '",
      src$resource, "'.\nThe release may have been moved or withdrawn; if the ",
      "URL has changed, please file an issue against canstreet.")))
  }

  for (i in which(!have)) {
    cs_message(quiet, "  ", todo$filename[i])
    cs_download(todo$url[i], todo$path[i], quiet = TRUE)
  }

  tibble::tibble(
    vintage = src$vintage,
    filename = todo$filename,
    path = todo$path,
    url = todo$url,
    label = todo$label
  )
}

#' Extract a downloaded archive into a scratch directory
#'
#' @param path Archive to extract.
#' @return Path to a directory holding the extracted files. The caller is
#'   responsible for removing it.
#' @keywords internal
#' @noRd
cs_extract <- function(path) {
  exdir <- file.path(tempdir(), paste0("canstreet_", basename(path), "_",
                                       as.integer(stats::runif(1, 1, 1e8))))
  dir.create(exdir, recursive = TRUE, showWarnings = FALSE)
  robust_unzip(path, exdir)
  exdir
}
