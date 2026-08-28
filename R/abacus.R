# Abacus Data Network (UBC) access.
#
# Abacus is a Dataverse instance. Its `statcan-public` collection carries the
# Statistics Canada Open Licence, the relevant files are unrestricted, and the
# native API needs no token. Datafiles are addressed by an integer id that is
# not derivable from the dataset handle, so the id has to be resolved from the
# dataset manifest -- which is cached, since it is stable and the request is
# the slow part of a small download.
#
# The DMTI Spatial collection on the same host is licence-restricted. It is
# deliberately not referenced anywhere in this package.

cs_abacus_dataset_url <- function(pid) {
  paste0(abacus_base, "/api/datasets/:persistentId/?persistentId=", pid)
}

cs_abacus_file_url <- function(id) {
  paste0(abacus_base, "/api/access/datafile/", id)
}

# Where the cached copy of a dataset manifest lives.
cs_abacus_manifest_path <- function(pid, cache_path) {
  slug <- gsub("[^A-Za-z0-9]+", "_", pid)
  file.path(cs_cache_dir(cache_path, "manifests"), paste0(slug, ".json"))
}

#' Resolve the file listing of an Abacus dataset
#'
#' @param pid Dataverse persistent identifier, e.g. `"hdl:11272.1/AB2/WFFBPW"`.
#' @param cache_path Directory the manifest is cached in.
#' @param refresh Re-fetch even when a cached manifest exists.
#' @param quiet Suppress progress messages.
#' @return A tibble with `id`, `filename`, `filesize`, `description`, `md5`.
#' @keywords internal
#' @noRd
cs_abacus_manifest <- function(pid, cache_path, refresh = FALSE, quiet = FALSE) {
  path <- cs_abacus_manifest_path(pid, cache_path)

  if (refresh || !file.exists(path)) {
    cs_message(quiet, "Resolving Abacus dataset ", pid, " ...")
    tmp <- tempfile(fileext = ".json")
    on.exit(unlink(tmp), add = TRUE)
    cs_download(cs_abacus_dataset_url(pid), tmp, quiet = TRUE)
    parsed <- tryCatch(jsonlite::fromJSON(tmp, simplifyVector = FALSE),
                       error = function(e) NULL)
    if (is.null(parsed) || !identical(parsed$status, "OK")) {
      stop(cs_network_error(paste0(
        "Abacus did not return a usable manifest for '", pid, "'.")))
    }
    file.copy(tmp, path, overwrite = TRUE)
  }

  parsed <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  files <- parsed$data$latestVersion$files
  if (!length(files)) {
    stop("Abacus dataset '", pid, "' lists no files.", call. = FALSE)
  }

  tibble::tibble(
    id = vapply(files, function(f) as.integer(f$dataFile$id), integer(1)),
    filename = vapply(files, function(f) as.character(f$dataFile$filename),
                      character(1)),
    filesize = vapply(files, function(f) as.numeric(f$dataFile$filesize),
                      numeric(1)),
    description = vapply(files, function(f) {
      as.character(f$dataFile$description %||% f$description %||% NA_character_)
    }, character(1)),
    restricted = vapply(files, function(f) isTRUE(f$restricted), logical(1))
  )
}

#' Select the datafiles of an Abacus dataset that belong to a vintage
#'
#' @param src A one-row source manifest entry from [cs_source()].
#' @inheritParams cs_abacus_manifest
#' @return A tibble of files to download, in filename order.
#' @keywords internal
#' @noRd
cs_abacus_select <- function(src, cache_path, refresh = FALSE, quiet = FALSE) {
  files <- cs_abacus_manifest(src$resource, cache_path, refresh = refresh,
                              quiet = quiet)

  keep <- grepl(src$file_pattern, files$filename, ignore.case = TRUE)
  if (!is.na(src$file_exclude)) {
    keep <- keep & !grepl(src$file_exclude, files$filename, ignore.case = TRUE)
  }
  files <- files[keep, , drop = FALSE]

  if (!nrow(files)) {
    stop("No files in Abacus dataset '", src$resource, "' match the pattern '",
         src$file_pattern, "'. The dataset may have been reorganised; please ",
         "file an issue.", call. = FALSE)
  }
  if (any(files$restricted)) {
    stop("Some matching files in '", src$resource, "' are access-restricted ",
         "and cannot be downloaded without credentials.", call. = FALSE)
  }

  files[order(files$filename), , drop = FALSE]
}
