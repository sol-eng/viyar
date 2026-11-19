skip_if_no_viya <- function() {
  url <- viya_config()$url
  if (!nzchar(url)) testthat::skip("VIYA_URL/viya_config(url=...) not set")
  tok <- tryCatch(viya_token(), error = function(e) "")
  if (!nzchar(tok)) testthat::skip("no Viya token available (run viya_login())")
}

# The Clinical Repository is a separately licensed offering (SAS Clinical
# Acceleration), so a cluster that passes skip_if_no_viya() may still have
# no /clinicalRepository service routed at all. Probe the service's own
# API root rather than assume.
skip_if_no_clinical <- function() {
  skip_if_no_viya()
  h  <- list(token = viya_token(), base = viya_config()$url)
  ok <- tryCatch({
    .viya_req(h, "/clinicalRepository/") |>
      httr2::req_perform() |> httr2::resp_body_json()
    TRUE
  }, error = function(e) FALSE)
  if (!ok)
    testthat::skip("no SAS Clinical Repository on this cluster")
}

# Clinical write tests share one long-lived organization. The test account
# can create an organization but not delete one (contexts need permanent
# deletion, a privilege it lacks -- found live), so a run must never create
# a new one. Each test instead gets its own folder inside it, deleted when
# the test ends. A deleted folder goes to the recycle bin.
.viya_live_clinical_org <- "/viyar_live_tests"

local_clinical_folder <- function(env = parent.frame()) {
  # Only a 404 means "missing". Any other failure (503, 401, timeout) must
  # propagate, never lead to creating an organization.
  have_org <- tryCatch({
    viya_clinical_item(.viya_live_clinical_org)
    TRUE
  }, error = function(e) if (inherits(e, "httr2_http_404")) FALSE else stop(e))
  if (!have_org)
    viya_clinical_create(.viya_live_clinical_org, "organization")
  path <- paste0(.viya_live_clinical_org, "/run_",
                 format(Sys.time(), "%Y%m%d_%H%M%S"), "_",
                 sample.int(1e6, 1))
  viya_clinical_create(path)
  # Found live: a folder holding a checked-out file can't be deleted, so a
  # test that checks a file out must defer its own undo. Deferred calls run
  # last-in-first-out, so that undo runs before this delete.
  withr::defer(
    tryCatch(viya_clinical_delete(path),
             error = function(e)
               warning("cleanup of ", path, " failed: ", conditionMessage(e))),
    envir = env)
  path
}

# Folder in SAS Content (Files service) that the live tests write into.
# Defaults to /Public; set VIYAR_TEST_FOLDER (or the viyar.test_folder
# option) to a folder your account can write to, e.g. "/Users/me/My Folder".
viya_test_folder <- function() {
  f <- getOption("viyar.test_folder", Sys.getenv("VIYAR_TEST_FOLDER", ""))
  sub("/+$", "", if (nzchar(f)) f else "/Public")
}

# Run a live-test setup write; skip the test, rather than error, when the
# account is not allowed to write to the test folder (HTTP 403).
skip_if_forbidden <- function(expr) {
  tryCatch(expr, httr2_http_403 = function(e)
    testthat::skip(paste0(
      "HTTP 403: this account cannot write to ", viya_test_folder(),
      "; set VIYAR_TEST_FOLDER to a folder it can write to")))
}

# A file that already has version history, for the read-only version tests.
# The test account cannot switch versioning on for a file it uploads (found
# live: uploads stay unversioned whatever check-in sends), so these tests read
# one that is already versioned instead of making one. Point
# VIYAR_LIVE_VERSIONED_FILE at your own cluster's equivalent.
skip_if_no_versioned_file <- function() {
  skip_if_no_clinical()
  path <- Sys.getenv("VIYAR_LIVE_VERSIONED_FILE",
                     "/PositLabs/Curanex-XR/data/adam/adsl.xpt")
  it <- tryCatch(viya_clinical_item(path), error = function(e) NULL)
  if (is.null(it) || !isTRUE(it$versioned))
    testthat::skip(paste0("no versioned file at ", path,
                          " (set VIYAR_LIVE_VERSIONED_FILE)"))
  path
}
