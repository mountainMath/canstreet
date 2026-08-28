#' Inspect the canstreet cache
#'
#' Reports what the cache holds: which vintages are imported, how many segments
#' each contributed, and how much disk the downloaded archives and the database
#' occupy.
#'
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()],
#'   which reads the `CANSTREET_CACHE_PATH` environment variable, then the
#'   `canstreet.cache_path` option, then falls back to [tempdir()]. Set it once
#'   with [set_canstreet_cache_path()] to keep data between sessions.
#'
#' @return A [tibble::tibble()] with one row per imported vintage --
#'   `vintage`, `n_segments`, `n_archives`, `raw_mb`, `imported_at`,
#'   `package_version` -- carrying the size of the database file in a
#'   `db_mb` attribute. Zero rows if nothing has been imported.
#'
#' @examples
#' list_canstreet_cache()
#' @export
list_canstreet_cache <- function(cache_path = canstreet_cache_path()) {
  empty <- tibble::tibble(
    vintage = integer(), n_segments = integer(), n_archives = integer(),
    raw_mb = numeric(), imported_at = character(),
    package_version = character())

  db <- cs_db_path(cache_path)
  if (!file.exists(db)) {
    attr(empty, "db_mb") <- 0
    return(empty)
  }

  con <- cs_connect(cache_path, read_only = TRUE)
  vintages <- cs_db_vintages(con)
  if (!length(vintages)) {
    attr(empty, "db_mb") <- round(file.size(db) / 1e6, 1)
    return(empty)
  }

  out <- tibble::tibble(
    vintage = vintages,
    n_segments = vapply(vintages, function(v) suppressWarnings(as.integer(
      cs_meta_value(con, v, "n_segments"))), integer(1)),
    n_archives = vapply(vintages, function(v) suppressWarnings(as.integer(
      cs_meta_value(con, v, "n_archives"))), integer(1)),
    raw_mb = vapply(vintages, function(v) {
      d <- file.path(cache_path, "downloads", as.character(v))
      if (!dir.exists(d)) return(0)
      round(sum(file.size(list.files(d, full.names = TRUE))) / 1e6, 1)
    }, numeric(1)),
    imported_at = vapply(vintages, function(v)
      cs_meta_value(con, v, "imported_at"), character(1)),
    package_version = vapply(vintages, function(v)
      cs_meta_value(con, v, "package_version"), character(1))
  )
  attr(out, "db_mb") <- round(file.size(db) / 1e6, 1)
  out
}

#' Remove a vintage from the canstreet cache
#'
#' Drops a vintage's table from the database and, optionally, its downloaded
#' archives.
#'
#' The archives are kept by default. They are the expensive part to re-acquire
#' -- several hundred megabytes each, from servers that are sometimes slow --
#' and keeping them means a vintage can be re-imported offline, for instance
#' after a package update changes the harmonized schema.
#'
#' Note that dropping a table does not shrink the database file: DuckDB reuses
#' the freed pages for later imports rather than returning them to the
#' filesystem. To actually reclaim the space, delete the file and re-import
#' from the retained archives.
#'
#' @param vintage Reference year to remove, or a vector of years.
#' @param keep_raw Keep the downloaded source archives. `FALSE` deletes them
#'   too, which means a later import has to download them again.
#' @param cache_path Cache directory. Defaults to [canstreet_cache_path()].
#'
#' @return The vintages removed, invisibly.
#'
#' @examples
#' \dontrun{
#' remove_canstreet_cache(2021)
#'
#' # Reclaim the disk as well.
#' remove_canstreet_cache(2021, keep_raw = FALSE)
#' }
#' @export
remove_canstreet_cache <- function(vintage, keep_raw = TRUE,
                                   cache_path = canstreet_cache_path()) {
  vintages <- vapply(vintage, cs_check_vintage, integer(1))

  if (file.exists(cs_db_path(cache_path))) {
    con <- cs_connect(cache_path, read_only = FALSE)
    for (v in vintages) {
      DBI::dbExecute(con, paste0(
        "DROP TABLE IF EXISTS ",
        DBI::dbQuoteIdentifier(con, cs_table_name(v))))
      if (DBI::dbExistsTable(con, "canstreet_metadata")) {
        DBI::dbExecute(con, "DELETE FROM canstreet_metadata WHERE vintage = ?;",
                       params = list(as.integer(v)))
      }
    }
    cs_rebuild_segments_view(con)
  }

  if (!keep_raw) {
    for (v in vintages) {
      unlink(file.path(cache_path, "downloads", as.character(v)),
             recursive = TRUE)
    }
  }
  invisible(vintages)
}
