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
  have_org <- tryCatch({
    viya_clinical_item(.viya_live_clinical_org)
    TRUE
  }, error = function(e) FALSE)
  if (!have_org)
    viya_clinical_create(.viya_live_clinical_org, "organization")
  path <- paste0(.viya_live_clinical_org, "/run_",
                 format(Sys.time(), "%Y%m%d_%H%M%S"), "_",
                 sample.int(1e6, 1))
  viya_clinical_create(path)
  # Found live: a folder holding a checked-out file can't be deleted, so a
  # test that checks a file out must defer its own undo. Deferred calls run
  # last-in-first-out, so that undo runs before this delete.
  withr::defer(try(viya_clinical_delete(path), silent = TRUE), envir = env)
  path
}
