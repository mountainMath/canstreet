# Gated on NOT_CRAN: the suite builds DuckDB databases and installs the spatial
# extension, which is more than a CRAN check machine should be asked to do.
if (identical(Sys.getenv("NOT_CRAN"), "true")) {
  library(testthat)
  library(canstreet)

  test_check("canstreet")
}
