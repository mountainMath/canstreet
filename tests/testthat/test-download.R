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
    cs_probe_url = function(url) "archive",
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
    cs_probe_url = function(url) "missing",
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

test_that("a Cloudflare challenge is told apart from a missing release", {
  # What www12.statcan.gc.ca answered a ranged GET with on 2026-10-09.
  challenge <- paste0(
    "HTTP/2 403\r\n",
    "content-type: text/html; charset=UTF-8\r\n",
    "content-length: 23628\r\n",
    "cf-mitigated: challenge\r\n",
    "server: cloudflare\r\n\r\n")
  expect_true(cs_headers_are_a_challenge(challenge))
  expect_false(cs_headers_are_an_archive(challenge))

  # The soft 404 is not a challenge, and neither is a real archive.
  expect_false(cs_headers_are_a_challenge(paste0(
    "HTTP/1.1 200 OK\r\n",
    "Content-Type: text/html; charset=UTF-8\r\n",
    "Content-Length: 4099\r\n\r\n")))
  expect_false(cs_headers_are_a_challenge(paste0(
    "HTTP/1.1 206 Partial Content\r\n",
    "Content-Type: application/x-zip-compressed\r\n",
    "Content-Range: bytes 0-0/262144000\r\n\r\n")))
})

test_that("a challenged StatCan file comes with manual-download instructions", {
  cache <- withr::local_tempdir()
  local_mocked_bindings(
    cs_probe_url = function(url) "challenge",
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop("cs_download() should not be reached")
  )

  err <- expect_error(
    canstreet_download(2021, quiet = TRUE, cache_path = cache),
    class = "canstreet_network_error")
  msg <- conditionMessage(err)
  dest <- file.path(cache, "downloads", "2021", "lrnf000r21a_e.zip")
  expect_match(msg, "browser check", fixed = TRUE)
  expect_match(msg, cs_source(2021)$resource, fixed = TRUE)
  expect_match(msg, file.path(normalizePath(dirname(dest)), basename(dest)),
               fixed = TRUE)

  # Depositing the file there, as the message says, is all it takes.
  file.create(dest)
  out <- canstreet_download(2021, quiet = TRUE, cache_path = cache)
  expect_identical(out$path, dest)
})

test_that("a failed StatCan fetch also says how to fetch it by hand", {
  cache <- withr::local_tempdir()
  local_mocked_bindings(
    cs_probe_url = function(url) "archive",
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop(cs_network_error("Could not download it."))
  )

  expect_error(canstreet_download(2021, quiet = TRUE, cache_path = cache),
               "Could not download it\\.\\nTo import this vintage")
})

test_that("a cached archive is not re-downloaded", {
  cache <- withr::local_tempdir()
  dir.create(file.path(cache, "downloads", "2021"), recursive = TRUE)
  file.create(file.path(cache, "downloads", "2021", "lrnf000r21a_e.zip"))

  local_mocked_bindings(
    cs_probe_url = function(url) stop("should not probe"),
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
    abacus_file(68308, "gsnf001r_e00.zip"),
    # Other members of the same dataset that the pattern must exclude: the
    # derived shapefiles, the block and hydrography polygons of the same unit,
    # and the documentation.
    abacus_file(68309, "gsnf001r_shp.zip"),
    abacus_file(68310, "gsnf002r_e00.zip"),
    abacus_file(68311, "gsnf001s_e00.zip"),
    abacus_file(68312, "readme.txt")))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...) {
      writeLines("x", destfile)
      invisible(0L)
    })

  out <- canstreet_download(1996, quiet = TRUE, cache_path = cache)

  expect_equal(out$filename, c("gsnf001r_e00.zip", "gsnf002r_e00.zip"))
  expect_match(out$url[1], "/api/access/datafile/68308$")
  expect_true(all(file.exists(out$path)))
  expect_equal(out$vintage, c(1996L, 1996L))
})

test_that("restricted Abacus files are refused rather than fetched", {
  cache <- withr::local_tempdir()
  src <- cs_source(1996)
  write_abacus_manifest(cache, src$resource,
                        list(abacus_file(1, "gsnf001r_e00.zip",
                                         restricted = TRUE)))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop("a restricted file must not be fetched"))

  expect_error(canstreet_download(1996, quiet = TRUE, cache_path = cache),
               "access-restricted")
})

test_that("the 1991 pattern takes the coverages, not the derived files", {
  cache <- withr::local_tempdir()
  src <- cs_source(1991)
  write_abacus_manifest(cache, src$resource, list(
    abacus_file(1, "net_hali.zip"),
    abacus_file(2, "net_othu.zip"),
    # The same networks as shapefiles, as MapInfo tables and as GeoJSON --
    # including the LSNF205 and OT_HULL Lambert twins, which would
    # double-count Halifax and Ottawa-Hull if a pattern ever let them in.
    abacus_file(3, "GSNF205_shp.zip"),
    abacus_file(4, "LSNF205_shp.zip"),
    abacus_file(5, "OT_HULL_shp.zip"),
    abacus_file(6, "gsnf205_mapinfo.zip"),
    abacus_file(7, "GSNF205_geojson.geojson")))

  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...) {
      writeLines("x", destfile); invisible(0L)
    })

  out <- canstreet_download(1991, quiet = TRUE, cache_path = cache)
  expect_equal(out$filename, c("net_hali.zip", "net_othu.zip"))
})

test_that("a hosted Area Master File vintage is fetched into the usual cache", {
  cache <- withr::local_tempdir()
  asked <- NULL
  local_mocked_bindings(
    # The probe is for Statistics Canada's soft 404; a missing object on the
    # hosted bucket is a real one.
    cs_probe_url = function(url) stop("should not probe"),
    cs_download = function(url, destfile, quiet = FALSE, ...) {
      asked <<- c(asked, url)
      file.create(destfile)
      invisible(destfile)
    }
  )

  out <- canstreet_download(1976, quiet = TRUE, cache_path = cache)
  expect_identical(asked, cs_source(1976)$resource)
  expect_identical(nrow(out), 1L)
  expect_identical(out$filename, "amf_1976.zip")
  expect_identical(out$path,
                   file.path(cache, "downloads", "1976", "amf_1976.zip"))
  expect_true(file.exists(out$path))

  # Once there, it is not asked for again.
  canstreet_download(1976, quiet = TRUE, cache_path = cache)
  expect_length(asked, 1L)
})

test_that("an unreachable bucket degrades to the same classed condition", {
  cache <- withr::local_tempdir()
  local_mocked_bindings(
    cs_download = function(url, destfile, quiet = FALSE, ...)
      stop(cs_network_error("HTTP status was '404 Not Found'"))
  )
  expect_error(canstreet_download(1986, quiet = TRUE, cache_path = cache),
               class = "canstreet_network_error")
  expect_length(list.files(file.path(cache, "downloads", "1986")), 0L)
})
