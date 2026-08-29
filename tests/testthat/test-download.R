# No test here touches the network: the two functions that do -- the
# availability probe and the fetch itself -- are mocked, which is also what
# lets the offline behaviour be asserted directly.

test_that("the availability probe reads a ranged response, not just a 200", {
  # What a ranged GET of a real archive returns: `206`, one byte in
  # `content-length`, and the file's real size after the slash.
  expect_true(cs_headers_are_an_archive(paste0(
    "HTTP/1.1 206 Partial Content\r\n",
    "Content-Type: application/x-zip-compressed\r\n",
    "Content-Length: 1\r\n",
    "Content-Range: bytes 0-0/262144000\r\n\r\n")))

  # Without the `content-range` reading, the one byte would fail the size test.
  expect_false(cs_headers_are_an_archive(paste0(
    "HTTP/1.1 206 Partial Content\r\n",
    "Content-Type: application/x-zip-compressed\r\n",
    "Content-Length: 1\r\n\r\n")))

  # The soft 404: a redirect to a landing page, served 200 and text/html.
  expect_false(cs_headers_are_an_archive(paste0(
    "HTTP/1.1 200 OK\r\n",
    "Content-Type: text/html; charset=UTF-8\r\n",
    "Content-Length: 4099\r\n\r\n")))

  # An unranged archive is still recognized, and a stub-sized zip is not.
  expect_true(cs_headers_are_an_archive(paste0(
    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\n",
    "Content-Length: 415236096\r\n\r\n")))
  expect_false(cs_headers_are_an_archive(paste0(
    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\n",
    "Content-Length: 4099\r\n\r\n")))
})

test_that("an unreachable host degrades to a classed condition", {
  cache <- withr::local_tempdir()
  local_mocked_bindings(
    cs_url_is_available = function(url) TRUE,
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop(cs_network_error("Could not resolve host: www12.statcan.gc.ca"))
  )

  expect_error(
    canstreet_download(2021, quiet = TRUE, cache_path = cache),
    class = "canstreet_network_error")

  # Nothing half-written is left behind for a later run to mistake for a
  # complete download.
  expect_length(list.files(file.path(cache, "downloads", "2021")), 0L)
})

test_that("a withdrawn StatCan release is reported, not silently saved", {
  cache <- withr::local_tempdir()
  # StatCan serves a missing release as a 302 to a landing page returned with
  # 200 OK and text/html, which download.file() would happily write as a .zip.
  local_mocked_bindings(
    cs_url_is_available = function(url) FALSE,
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop("cs_download() should not be reached")
  )

  expect_error(
    canstreet_download(2021, quiet = TRUE, cache_path = cache),
    class = "canstreet_network_error")
  expect_error(
    canstreet_download(2021, quiet = TRUE, cache_path = cache),
    "moved or withdrawn")
})

test_that("a cached archive is not re-downloaded", {
  cache <- withr::local_tempdir()
  dir.create(file.path(cache, "downloads", "2021"), recursive = TRUE)
  file.create(file.path(cache, "downloads", "2021", "lrnf000r21a_e.zip"))

  local_mocked_bindings(
    cs_url_is_available = function(url) stop("should not probe"),
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop("should not download")
  )

  out <- canstreet_download(2021, quiet = TRUE, cache_path = cache)
  expect_equal(nrow(out), 1L)
  expect_equal(out$vintage, 2021L)
  expect_true(file.exists(out$path))

  # refresh = TRUE ignores the cache.
  expect_error(canstreet_download(2021, quiet = TRUE, refresh = TRUE,
                                  cache_path = cache), "should not probe")
})

# Stand in for the Dataverse dataset JSON, written into the manifest cache so
# the real parsing path runs and only the fetch is mocked.
write_abacus_manifest <- function(cache, pid, files) {
  path <- cs_abacus_manifest_path(pid, cache)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(jsonlite::toJSON(list(
    status = "OK",
    data = list(latestVersion = list(files = files))
  ), auto_unbox = TRUE), path)
  path
}

abacus_file <- function(id, filename, restricted = FALSE) {
  list(restricted = restricted,
       dataFile = list(id = id, filename = filename, filesize = 1024,
                       description = paste("fixture", filename)))
}

test_that("an Abacus vintage resolves file ids through the dataset manifest", {
  cache <- withr::local_tempdir()
  src <- cs_source(1996)
  write_abacus_manifest(cache, src$resource, list(
    abacus_file(68308, "gsnf001r_shp.zip"),
    # Other members of the same dataset that the pattern must exclude.
    abacus_file(68309, "gsnf001r_e00.zip"),
    abacus_file(68310, "gsnf002r_shp.zip"),
    abacus_file(68311, "readme.txt")))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...) {
      writeLines("x", destfile)
      invisible(0L)
    })

  out <- canstreet_download(1996, quiet = TRUE, cache_path = cache)

  expect_equal(out$filename, c("gsnf001r_shp.zip", "gsnf002r_shp.zip"))
  expect_match(out$url[1], "/api/access/datafile/68308$")
  expect_true(all(file.exists(out$path)))
  expect_equal(out$vintage, c(1996L, 1996L))
})

test_that("restricted Abacus files are refused rather than fetched", {
  cache <- withr::local_tempdir()
  src <- cs_source(1996)
  write_abacus_manifest(cache, src$resource,
                        list(abacus_file(1, "gsnf001r_shp.zip",
                                         restricted = TRUE)))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop("a restricted file must not be fetched"))

  expect_error(canstreet_download(1996, quiet = TRUE, cache_path = cache),
               "access-restricted")
})

test_that("the 1991 exclusions keep the Lambert twins out", {
  cache <- withr::local_tempdir()
  src <- cs_source(1991)
  write_abacus_manifest(cache, src$resource, list(
    abacus_file(1, "GSNF205_shp.zip"),
    # LSNF205 and OT_HULL are the same networks in Lambert; importing both
    # would double-count Halifax and Ottawa-Hull.
    abacus_file(2, "LSNF205_shp.zip"),
    abacus_file(3, "HULL_OTT_shp.zip"),
    abacus_file(4, "OT_HULL_shp.zip")))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...) {
      writeLines("x", destfile); invisible(0L)
    })

  out <- canstreet_download(1991, quiet = TRUE, cache_path = cache)
  expect_equal(out$filename, c("GSNF205_shp.zip", "HULL_OTT_shp.zip"))
})
