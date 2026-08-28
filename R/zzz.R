.onAttach <- function(libname, pkgname) {
  if (cs_cache_path_is_set()) {
    packageStartupMessage("canstreet cache: ", canstreet_cache_path())
    return(invisible())
  }
  packageStartupMessage(cs_cache_path_hint("canstreet cache path is not set"))
}
