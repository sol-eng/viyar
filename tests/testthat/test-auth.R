mk_jwt <- function(exp) {
  payload <- as.character(jsonlite::toJSON(list(exp = exp), auto_unbox = TRUE))
  seg <- chartr("+/", "-_", sub("=+$", "", openssl::base64_encode(charToRaw(payload))))
  paste("h", seg, "s", sep = ".")
}

reset_token_cache <- function() {
  rm(list = ls(envir = .token_cache), envir = .token_cache)
}

test_that("VIYA_TOKEN env var always wins", {
  withr::local_envvar(VIYA_TOKEN = "env-token")
  expect_equal(viya_token(), "env-token")
})

test_that("a fresh cached token is returned without any network call", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  .token_cache$tok <- "cached-tok"
  .token_cache$exp <- Sys.time() + 3600
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  httr2::local_mocked_responses(function(req) stop("should not hit the network"))
  expect_equal(viya_token(), "cached-tok")
})

test_that("an expired cached token refreshes via the stored refresh_token", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  .token_cache$tok <- mk_jwt(as.numeric(Sys.time()) - 10)
  .token_cache$exp <- .jwt_exp(.token_cache$tok)
  .token_cache$refresh <- "refresh-abc"
  .token_cache$client_id <- "vscode-positron"
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")

  new_access <- mk_jwt(as.numeric(Sys.time()) + 36000)
  resp <- httr2::response_json(status = 200, body = list(
    access_token = new_access, refresh_token = "refresh-def"))
  seen <- NULL
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_token()
  expect_equal(out, new_access)
  expect_equal(as.character(seen$body$data$grant_type), "refresh_token")
  expect_equal(as.character(seen$body$data$refresh_token), "refresh-abc")
  expect_equal(.token_cache$refresh, "refresh-def")
})

test_that("Workbench managed OAuth is tried when rstudioapi reports available", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  tok <- mk_jwt(as.numeric(Sys.time()) + 36000)
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(guid = "guid-1"),
    getOAuthCredentials = function(...) list(access_token = tok),
    .package = "rstudioapi")

  expect_equal(viya_token(), tok)
  expect_equal(.token_cache$tok, tok)
})

test_that("a non-Workbench RStudio/Positron session falls through instead of erroring", {
  # isAvailable() is TRUE outside Workbench too (plain RStudio Desktop, a
  # local Positron session); findOAuthIntegration() itself asserts a real
  # Workbench session and throws otherwise -- viya_token() must catch that
  # and fall through to its next resolution step, not propagate the error.
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...)
      stop("assertWorkbenchSession(): only available within Posit Workbench sessions"),
    .package = "rstudioapi")

  expect_error(viya_token(), "viya_login\\(\\)")
})

test_that("a clear error is thrown when nothing is available", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  expect_error(viya_token(), "viya_login\\(\\)")
})

test_that(".viya_url_from_integration strips the /SASLogon suffix", {
  expect_equal(
    .viya_url_from_integration(list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token")),
    "https://viya.pcluster.soleng.posit.it")
  expect_equal(
    .viya_url_from_integration(list(
      token_url = "https://viya.example.com/SASLogon/oauth/token")),
    "https://viya.example.com")
  expect_null(.viya_url_from_integration(list()))
})

test_that("viya_config() auto-detects the URL from Workbench when unset", {
  withr::local_envvar(VIYA_URL = "")
  withr::local_options(viyar.url = NULL)
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token"),
    .package = "rstudioapi")

  expect_equal(viya_config()$url, "https://viya.pcluster.soleng.posit.it")
})

test_that("viya_config() prefers an explicitly configured URL over auto-detection", {
  withr::local_envvar(VIYA_URL = "")
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(
      issuer = "https://auto-detected.example.com/SASLogon/oauth/token"),
    .package = "rstudioapi")

  viya_config(url = "https://explicit.example.com")
  expect_equal(viya_config()$url, "https://explicit.example.com")
  withr::local_options(viyar.url = NULL)
})
