# The browser route for a Statistics Canada download.
#
# Since October 2026 Cloudflare fronts www12.statcan.gc.ca and answers
# scripted requests with a browser check. A real browser passes it, and the
# `safeconduct` package (by the same author; github.com/mountainMath/safeconduct)
# is what opens one: a Chrome window with a throwaway profile, the check left
# to run on its own, and the file then fetched through curl with the clearance
# the browser was given, or in the window itself when the server will serve
# only the browser. What was learned about the check -- headless never passes,
# a visible window usually does, Cloudflare escalates to a "Verify you are
# human" box after repeated challenges from one address, and nothing may click
# that box but the person at the screen -- is recorded in safeconduct's
# `R/chrome.R`, not repeated here.
#
# This module is the seam: it says whether the route is open on this machine,
# and maps safeconduct's classed errors onto canstreet's two outcomes. "No
# browser" and "did not pass" both mean the manual-download instructions
# (`cs_manual_download_error()`); a transfer that fails is a network error
# like any other. `safeconduct` is in Suggests, so a user who never meets the
# check never installs Chrome's tooling.

# Why the browser route cannot be taken here, or NULL when it can.
cs_browser_unavailable_reason <- function() {
  if (!isTRUE(getOption("canstreet.browser", TRUE)))
    return("the `canstreet.browser` option is FALSE")
  if (!requireNamespace("safeconduct", quietly = TRUE))
    return("the `safeconduct` package is not installed")
  ok <- safeconduct::browser_available()
  if (!isTRUE(ok)) return(attr(ok, "reason"))
  NULL
}

# Fetch a file that stands behind a browser check. TRUE when it is at
# `destfile`, FALSE when the route is closed or the check was not passed, so
# that the caller can fall back to the manual instructions; a transfer that
# fails is a `canstreet_network_error`.
cs_fetch_challenged <- function(url, destfile, quiet = FALSE) {
  if (!is.null(cs_browser_unavailable_reason())) return(FALSE)
  tryCatch({
    safeconduct::fetch(url, destfile, quiet = quiet)
    TRUE
  },
  safeconduct_unavailable = function(e) FALSE,
  safeconduct_not_passed = function(e) FALSE,
  safeconduct_download_error = function(e)
    stop(cs_network_error(conditionMessage(e))))
}

# The first line of the manual-download error after a challenge: what stood in
# the way, and -- when it was the browser route being unavailable -- what
# would open it.
cs_challenge_why <- function(vintage) {
  reason <- cs_browser_unavailable_reason()
  paste0(
    "Statistics Canada is answering automated requests for the ", vintage,
    " road network file with a browser check (Cloudflare), ",
    if (is.null(reason))
      "and the Chrome window canstreet opened did not get past it."
    else paste0(
      "which canstreet can pass by opening a Chrome window, but ", reason, ".",
      if (grepl("package", reason, fixed = TRUE))
        paste0("\nInstall it with remotes::install_github(\"mountainMath/",
               "safeconduct\") and have Chrome on this machine.")
      else ""))
}
