test_that("the cache path resolves env var over option over tempdir", {
  withr::local_envvar(CANSTREET_CACHE_PATH = NA)
  withr::local_options(canstreet.cache_path = NULL)
  expect_equal(canstreet_cache_path(), tempdir())
  expect_false(cs_cache_path_is_set())

  withr::local_options(canstreet.cache_path = "~/opt-cache")
  expect_equal(canstreet_cache_path(), path.expand("~/opt-cache"))
  expect_true(cs_cache_path_is_set())

  # The environment variable wins, so a shell setting overrides a stale option
  # left in an .Rprofile.
  withr::local_envvar(CANSTREET_CACHE_PATH = "~/env-cache")
  expect_equal(canstreet_cache_path(), path.expand("~/env-cache"))
})

test_that("an empty setting is treated as unset", {
  withr::local_envvar(CANSTREET_CACHE_PATH = "")
  withr::local_options(canstreet.cache_path = "")
  expect_equal(canstreet_cache_path(), tempdir())
})

test_that("set_canstreet_cache_path sets the session without touching .Renviron", {
  withr::local_envvar(CANSTREET_CACHE_PATH = NA)
  target <- withr::local_tempdir()

  expect_message(out <- set_canstreet_cache_path(target, install = FALSE),
                 "this session only")
  expect_equal(out, path.expand(target))
  expect_equal(canstreet_cache_path(), path.expand(target))
  withr::defer(Sys.unsetenv("CANSTREET_CACHE_PATH"))

  # The directory is created, since every caller assumes it exists.
  expect_true(dir.exists(target))
})

test_that("show_canstreet_cache_path reports where the setting came from", {
  withr::local_envvar(CANSTREET_CACHE_PATH = NA)
  withr::local_options(canstreet.cache_path = NULL)
  expect_message(show_canstreet_cache_path(), "No cache path is set")

  withr::local_envvar(CANSTREET_CACHE_PATH = "~/env-cache")
  expect_message(show_canstreet_cache_path(), "environment variable")
})

test_that("the download warning fires once per session", {
  withr::local_envvar(CANSTREET_CACHE_PATH = NA)
  withr::local_options(canstreet.cache_path = NULL)
  cs_session_state$download_cache_warned <- FALSE
  withr::defer(cs_session_state$download_cache_warned <- FALSE)

  expect_warning(cs_warn_cache_path_on_download(tempdir()),
                 "set_canstreet_cache_path")
  expect_silent(cs_warn_cache_path_on_download(tempdir()))

  # No nagging when a real cache path is configured.
  withr::local_envvar(CANSTREET_CACHE_PATH = "~/env-cache")
  cs_session_state$download_cache_warned <- FALSE
  expect_silent(cs_warn_cache_path_on_download(path.expand("~/env-cache")))
})
