# Precompute the vignettes.
#
# The vignettes query real road network files, which means downloading several
# hundred megabytes and a few minutes of build -- far more than a package build
# or a CRAN check should do. So each vignette is *written* here, in
# `vignettes.orig/`, and knitted into the `vignettes/` directory that ships,
# where the `.Rmd` that R CMD build sees holds the results already.
#
# Both directories hold plain `.Rmd` files, so an editor treats the source as
# R Markdown; `vignettes.orig/` is .Rbuildignore'd, so none of it is shipped.
#
#   Rscript vignettes.orig/precompute.R                  # all of them
#   Rscript vignettes.orig/precompute.R canstreet        # just this one
#   Rscript vignettes.orig/precompute.R canstreet-vancouver canstreet-temporal
#
# Name a subset while iterating: a full pass rebuilds two temporal networks and
# takes minutes, and each vignette is independent of the others. Commit the
# resulting `vignettes/*.Rmd` together with any figures it wrote.

if (!nzchar(Sys.getenv("CANSTREET_CACHE_PATH")) &&
    is.null(getOption("canstreet.cache_path"))) {
  stop("Set CANSTREET_CACHE_PATH before precomputing, or the vignettes will ",
       "download every vintage into a tempdir that is then discarded.")
}

# Where this script lives, so it works from the package root or from anywhere
# else. `--file=` is absent when the script is sourced rather than Rscript'ed,
# in which case fall back to the package root's own layout.
this <- grep("^--file=", commandArgs(), value = TRUE)
src_dir <- if (length(this)) dirname(sub("^--file=", "", this[1])) else
  "vignettes.orig"
src_dir <- normalizePath(src_dir, mustWork = TRUE)
out_dir <- normalizePath(file.path(src_dir, "..", "vignettes"), mustWork = TRUE)

devtools::load_all(file.path(src_dir, ".."), quiet = TRUE)

available <- sub("\\.Rmd$", "", list.files(src_dir, pattern = "\\.Rmd$"))
wanted <- sub("\\.Rmd$", "", commandArgs(trailingOnly = TRUE))
if (!length(wanted)) wanted <- available

unknown <- setdiff(wanted, available)
if (length(unknown)) {
  stop("No such vignette source: ", paste(unknown, collapse = ", "),
       ". Available: ", paste(available, collapse = ", "))
}

# knit from within `vignettes/`, because `fig.path` is relative to the working
# directory and the figures have to land beside the `.Rmd` that ships.
old <- setwd(out_dir)
on.exit(setwd(old), add = TRUE)

for (v in wanted) {
  message("knitting ", v)
  knitr::knit(file.path(src_dir, paste0(v, ".Rmd")), paste0(v, ".Rmd"))

  # Say so in the file itself, so an edit to the wrong copy is obvious.
  lines <- readLines(paste0(v, ".Rmd"), warn = FALSE)
  end <- if (identical(trimws(lines[1]), "---")) {
    which(trimws(lines[-1]) == "---")[1] + 1L
  } else 0L
  writeLines(append(lines, c(
    paste0("<!-- Generated from vignettes.orig/", v, ".Rmd -- do not edit. -->"),
    "<!-- Rebuild with: Rscript vignettes.orig/precompute.R -->"),
    after = end), paste0(v, ".Rmd"))
}

canstreet_disconnect()
