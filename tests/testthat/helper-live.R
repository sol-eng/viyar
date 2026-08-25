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
