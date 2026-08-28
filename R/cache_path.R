# Cache location.
#
# These files are large -- a national vintage is ~300 MB of source archive on
# top of what it adds to the database -- so re-downloading them because the
# cache went to tempdir() is an expensive accident. The path is resolved from,
# in order: the CANSTREET_CACHE_PATH environment variable, the
# `canstreet.cache_path` option, and finally tempdir(). The environment
# variable is the recommended one because it persists across sessions through
# .Renviron; the option matches the other packages in this family.

#' The directory canstreet caches data in
#'
#' Resolves the cache location from, in order, the `CANSTREET_CACHE_PATH`
#' environment variable, the `canstreet.cache_path` option, and finally
#' [tempdir()]. Every function that downloads or reads data takes a
#' `cache_path` argument defaulting to this.
#'
#' Downloaded archives are kept under `downloads/` and the harmonized data in
#' `canstreet.duckdb`, both inside this directory. Falling back to `tempdir()`
#' means everything is discarded when the session ends and re-downloaded next
#' time, so setting a real path is strongly recommended -- see
#' [set_canstreet_cache_path()].
#'
#' @return A file path, with `~` expanded.
#'
#' @examples
#' canstreet_cache_path()
#' @export
canstreet_cache_path <- function() {
  path <- Sys.getenv("CANSTREET_CACHE_PATH")
  if (!nzchar(path)) path <- getOption("canstreet.cache_path", "")
  if (!nzchar(path)) return(tempdir())
  path.expand(path)
}

#' Set the canstreet cache location
#'
#' Points canstreet at a directory to keep downloaded archives and the
#' harmonized database in. With `install = TRUE` the setting is written to your
#' `.Renviron` so it applies to every future session, which is what you want:
#' without it, several hundred megabytes per vintage are re-downloaded each
#' time you restart R.
#'
#' @param cache_path Directory to cache data in, e.g. `"~/data/canstreet"`. It
#'   is created if it does not exist.
#' @param overwrite Replace a `CANSTREET_CACHE_PATH` already in `.Renviron`.
#' @param install Write the setting to `.Renviron` so it persists across
#'   sessions. When `FALSE` it applies to this session only.
#'
#' @return `cache_path`, invisibly.
#'
#' @examples
#' \dontrun{
#' # This session only.
#' set_canstreet_cache_path("~/data/canstreet")
#'
#' # Permanently.
#' set_canstreet_cache_path("~/data/canstreet", install = TRUE)
#' }
#' @export
set_canstreet_cache_path <- function(cache_path, overwrite = FALSE,
                                     install = FALSE) {
  if (!is.character(cache_path) || length(cache_path) != 1L ||
      !nzchar(cache_path)) {
    stop("`cache_path` must be a single non-empty directory path.",
         call. = FALSE)
  }
  expanded <- path.expand(cache_path)
  if (!dir.exists(expanded)) {
    dir.create(expanded, recursive = TRUE, showWarnings = FALSE)
  }

  if (install) {
    renv <- file.path(Sys.getenv("HOME"), ".Renviron")
    if (!file.exists(renv)) {
      file.create(renv)
    } else {
      # Back up before touching a file the user did not write for us.
      file.copy(renv, file.path(Sys.getenv("HOME"), ".Renviron_backup"),
                overwrite = TRUE)
      lines <- readLines(renv, warn = FALSE)
      hit <- grepl("^\\s*CANSTREET_CACHE_PATH\\s*=", lines)
      if (any(hit)) {
        if (!isTRUE(overwrite)) {
          stop("CANSTREET_CACHE_PATH is already set in ", renv,
               ". Pass overwrite = TRUE to replace it.", call. = FALSE)
        }
        writeLines(lines[!hit], renv)
      }
    }
    write(paste0("CANSTREET_CACHE_PATH='", cache_path, "'"), renv,
          append = TRUE)
    message("Cache path written to ", renv,
            "; it will apply to new R sessions.")
  } else {
    message("Cache path set for this session only. Re-run with ",
            "install = TRUE to persist it across sessions.")
  }

  Sys.setenv(CANSTREET_CACHE_PATH = cache_path)
  invisible(cache_path)
}

#' Report where canstreet is caching data, and how that was decided
#'
#' @return The resolved cache path, invisibly.
#'
#' @examples
#' show_canstreet_cache_path()
#' @export
show_canstreet_cache_path <- function() {
  env <- Sys.getenv("CANSTREET_CACHE_PATH")
  # An empty option is no option, matching canstreet_cache_path().
  opt <- getOption("canstreet.cache_path", "")

  if (nzchar(env)) {
    message("Cache path: ", path.expand(env),
            "\n  set by the CANSTREET_CACHE_PATH environment variable.")
  } else if (nzchar(opt)) {
    message("Cache path: ", path.expand(opt),
            "\n  set by the `canstreet.cache_path` option.\n",
            "  Consider `set_canstreet_cache_path(getOption(",
            "\"canstreet.cache_path\"), install = TRUE)` so it also applies ",
            "to new sessions.")
  } else {
    message(cs_cache_path_hint("No cache path is set"))
  }
  invisible(canstreet_cache_path())
}

# Shared, copy-pasteable instructions, used by the startup message, the
# first-download warning, and show_canstreet_cache_path().
cs_cache_path_hint <- function(prefix) {
  paste0(
    prefix, ".\n",
    "Downloads go to tempdir() and are discarded when this R session ends, ",
    "so several hundred MB per vintage would be fetched again next time.\n",
    "To keep them, set a cache directory:\n",
    '  set_canstreet_cache_path("~/data/canstreet", install = TRUE)')
}

# Tracks once-per-session advisories.
cs_session_state <- new.env(parent = emptyenv())

cs_cache_path_is_set <- function() {
  nzchar(Sys.getenv("CANSTREET_CACHE_PATH")) ||
    nzchar(getOption("canstreet.cache_path", ""))
}

# Warn at most once per session, the first time a download is about to run
# against a cache that will not survive the session.
cs_warn_cache_path_on_download <- function(cache_path) {
  if (cs_cache_path_is_set()) return(invisible(FALSE))
  # A caller that passed an explicit path knows what it is doing.
  if (!identical(normalizePath(cache_path, mustWork = FALSE),
                 normalizePath(tempdir(), mustWork = FALSE))) {
    return(invisible(FALSE))
  }
  if (isTRUE(cs_session_state[["download_cache_warned"]])) {
    return(invisible(FALSE))
  }
  cs_session_state[["download_cache_warned"]] <- TRUE
  warning(cs_cache_path_hint("No canstreet cache path is set"), call. = FALSE)
  invisible(TRUE)
}
