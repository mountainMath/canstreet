# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`canstreet` is an R package (by Jens von Bergmann / MountainMath) for downloading and processing
**historical Statistics Canada road/street network files**, so the evolution of the Canadian road
network over time can be analysed reproducibly.

**The repo is currently an unmodified RStudio package skeleton.** `R/hello.R`, `man/hello.Rd`, and the
placeholder fields in `DESCRIPTION` (Title, Authors@R "Jane Doe", Description, License) are template
boilerplate, not real code — delete/replace them rather than building on them. `README.md` is the only
file that states actual intent.

## Commands

Development uses devtools (the `.Rproj` sets `PackageUseDevtools: Yes`). From the package root:

```r
devtools::load_all()            # load package for interactive work (Cmd+Shift+L in RStudio)
devtools::document()            # regenerate NAMESPACE + man/ from roxygen comments
devtools::test()                # run all tests
devtools::test(filter = "foo")  # run only tests/testthat/test-foo.R
testthat::test_file("tests/testthat/test-foo.R")
devtools::check()               # full R CMD check (run before any release)
devtools::install()
```

From the shell: `R -q -e 'devtools::load_all(); devtools::test()'` or `R CMD build . && R CMD check canstreet_*.tar.gz`.

There is no test infrastructure yet — set it up with `usethis::use_testthat(3)` before writing the first test.

## Conventions

- **Roxygen is the source of truth for `NAMESPACE` and `man/`.** The `.Rproj` has
  `PackageRoxygenize: rd,collate,namespace`, so `devtools::document()` overwrites both. The current
  `NAMESPACE` (`exportPattern("^[[:alpha:]]+")`) is skeleton output and will be replaced by explicit
  `@export` tags on first `document()` — never hand-edit `NAMESPACE` or files in `man/`.
- 2-space indent, no tabs, UTF-8, trailing whitespace stripped (per `.Rproj`).

## Sibling packages as prior art

The author maintains a family of StatCan-data packages in `/Users/jens/R` — most relevantly
`canpumf` (download + parse StatCan bulk files), `cansim`, `cancensus`, and `cangeocode`. When
designing this package's API, match their established patterns rather than inventing new ones:

- **Caching**: user-facing download functions take a `cache_path` argument defaulting to
  `getOption("canstreet.cache_path", tempdir())`, with data laid out under
  `<cache_path>/<collection>/<version>/`.
- Tidyverse-style stack (`dplyr`, `readr`, `stringr`, `purrr`, `rlang`, `httr`/`rvest` for
  scraping StatCan pages), tibbles returned from user-facing functions; here geometry work will
  additionally mean `sf`.
- Module layout by concern (e.g. `R/api.R`, `R/pipeline.R`, `R/cache_mgmt.R`, `R/helpers.R`) rather
  than one file per function.
- StatCan data is redistributed under the Statistics Canada Open Licence — cite it in `DESCRIPTION`
  and in the docs of functions that download data, as the sibling packages do.
