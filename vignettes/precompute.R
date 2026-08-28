# Precompute the vignettes.
#
# The vignettes query real road network files, which means downloading several
# hundred megabytes and a few minutes of import -- far more than a package
# build or a CRAN check should do. So each vignette is written as a `.Rmd.orig`
# that is knitted here, against a real cache, into the `.Rmd` that ships. Run
# this by hand after changing a `.Rmd.orig`, and commit the resulting `.Rmd`
# together with any figures.
#
#   Rscript vignettes/precompute.R
#
# Both the `.Rmd.orig` files and this script are .Rbuildignore'd.

if (!nzchar(Sys.getenv("CANSTREET_CACHE_PATH")) &&
    is.null(getOption("canstreet.cache_path"))) {
  stop("Set CANSTREET_CACHE_PATH before precomputing, or the vignettes will ",
       "download every vintage into a tempdir that is then discarded.")
}

devtools::load_all(quiet = TRUE)

old <- setwd("vignettes")
on.exit(setwd(old), add = TRUE)

for (f in list.files(".", pattern = "\\.Rmd\\.orig$")) {
  message("knitting ", f)
  knitr::knit(f, sub("\\.orig$", "", f))
}

canstreet_disconnect()
