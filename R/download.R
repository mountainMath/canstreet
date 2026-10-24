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
#' Data are downloaded from Statistics Canada where it still serves them
#' (2001 onwards), from the Abacus Data Network at the University of British
#' Columbia (1991 and 1996), and from MountainMath's own storage for the
#' 1971 to 1986 Area Master Files, which Statistics Canada does not serve
#' online. All of it is Statistics Canada data,
#' distributed under the Statistics Canada Open Licence
#' (<https://www.statcan.gc.ca/en/reference/licence>).
#'
#' @section The Statistics Canada browser check:
#' Statistics Canada's download server answers requests that do not come from
#' a web browser with a Cloudflare browser check instead of the file. When
#' that happens, `canstreet_download()` opens a Chrome window with a
#' throwaway profile and lets the check run. The download then goes through
#' curl, carrying what the browser was given, and the window closes after a
#' few seconds; when the server will serve only the browser itself, the file
#' is downloaded in the window, which stays open until it is done.
#' Occasionally the check asks for a click on a "Verify you are human" box,
#' which is yours to give. This needs the `safeconduct` package
#' (`remotes::install_github("mountainMath/safeconduct")`) and a Chrome or
#' Chromium installation (set the `CHROMOTE_CHROME` environment variable if it
#' is somewhere unusual), and a display to show the window on. Set
#' `options(canstreet.browser = FALSE)` to never open one. Without the browser
#' route, or when it does not get through, the error says which file to
#' download by hand and the exact cache path to save it to; the next call
#' imports it from there. None of this runs when Statistics Canada serves the
#' file directly.
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
    statcan = ,
    mountainmath = tibble::tibble(
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
  #
  # A bot challenge in front of the file (see `cs_headers_are_a_challenge()`)
  # is not a missing release: a browser still gets the file. So one is opened
  # to pass the check (`R/clearance.R`, through the safeconduct package), and
  # the download then carries what it earned. When no browser can be had, or
  # it does not pass, the error says
  # where to fetch the file and where to put it; a failed fetch from StatCan
  # says the same. All of it is decided on what the server answers now, so
  # nothing needs undoing when the challenge goes away.
  is_statcan <- identical(src$host, "statcan")
  manual <- function(i, why) {
    stop(cs_manual_download_error(todo$url[i], todo$path[i], why))
  }
  if (is_statcan && any(!have)) {
    # A StatCan vintage is one archive.
    i <- which(!have)
    probe <- cs_probe_url(todo$url[i])
    if (identical(probe, "challenge")) {
      cs_message(quiet, "  ", todo$filename[i])
      fetched <- tryCatch(
        cs_fetch_challenged(todo$url[i], todo$path[i], quiet = quiet),
        canstreet_network_error = function(e) manual(i, conditionMessage(e)))
      if (!isTRUE(fetched)) manual(i, cs_challenge_why(src$vintage))
      have[i] <- TRUE
    } else if (!identical(probe, "archive")) {
      stop(cs_network_error(paste0(
        "Statistics Canada is not serving a road network file at '",
        todo$url[i], "'.\nThe release may have been moved or withdrawn; if ",
        "the URL has changed, please file an issue against canstreet.")))
    }
  }

  for (i in which(!have)) {
    cs_message(quiet, "  ", todo$filename[i])
    if (is_statcan) {
      tryCatch(cs_download(todo$url[i], todo$path[i], quiet = TRUE),
               canstreet_network_error = function(e)
                 manual(i, conditionMessage(e)))
    } else {
      cs_download(todo$url[i], todo$path[i], quiet = TRUE)
    }
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
