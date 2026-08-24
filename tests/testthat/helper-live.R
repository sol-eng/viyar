skip_if_no_viya <- function() {
  url <- viya_config()$url
  if (!nzchar(url)) testthat::skip("VIYA_URL/viya_config(url=...) not set")
  tok <- tryCatch(viya_token(), error = function(e) "")
  if (!nzchar(tok)) testthat::skip("no Viya token available (run viya_login())")
}
