mk_jwt <- function(exp) {
  payload <- as.character(jsonlite::toJSON(list(exp = exp), auto_unbox = TRUE))
  seg <- chartr("+/", "-_", sub("=+$", "", openssl::base64_encode(charToRaw(payload))))
  paste("h", seg, "s", sep = ".")
}

test_that("VIYA_TOKEN env var always wins", {
  withr::local_envvar(VIYA_TOKEN = "env-token")
  expect_equal(viya_token(), "env-token")
})

test_that("a fresh cached token is returned without any network call", {
  withr::local_envvar(VIYA_TOKEN = "")
  local_token_cache()
  .token_cache$tok <- "cached-tok"
  .token_cache$exp <- Sys.time() + 3600
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  httr2::local_mocked_responses(function(req) stop("should not hit the network"))
  expect_equal(viya_token(), "cached-tok")
})

test_that("an expired cached token refreshes via the stored refresh_token", {
  withr::local_envvar(VIYA_TOKEN = "")
  local_token_cache()
  .token_cache$tok <- mk_jwt(as.numeric(Sys.time()) - 10)
  .token_cache$exp <- .jwt_exp(.token_cache$tok)
  .token_cache$refresh <- "refresh-abc"
  .token_cache$client_id <- "vscode-positron"
  .token_cache$url <- "https://viya.example.com"
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")

  new_access <- mk_jwt(as.numeric(Sys.time()) + 36000)
  resp <- httr2::response_json(status = 200, body = list(
    access_token = new_access, refresh_token = "refresh-def"))
  seen <- NULL
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_token()
  expect_equal(out, new_access)
  expect_equal(seen$url, "https://viya.example.com/SASLogon/oauth/token")
  expect_equal(as.character(seen$body$data$grant_type), "refresh_token")
  expect_equal(as.character(seen$body$data$refresh_token), "refresh-abc")
  expect_equal(.token_cache$refresh, "refresh-def")
})

test_that("a refresh response omitting refresh_token preserves the existing one", {
  withr::local_envvar(VIYA_TOKEN = "")
  local_token_cache()
  .token_cache$tok <- mk_jwt(as.numeric(Sys.time()) - 10)
  .token_cache$exp <- .jwt_exp(.token_cache$tok)
  .token_cache$refresh <- "refresh-abc"
  .token_cache$client_id <- "vscode-positron"
  .token_cache$url <- "https://viya.example.com"
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")

  new_access <- mk_jwt(as.numeric(Sys.time()) + 36000)
  # Server does NOT include refresh_token in this response (non-rotating server).
  resp <- httr2::response_json(status = 200, body = list(access_token = new_access))
  httr2::local_mocked_responses(list(resp))

  out <- viya_token()
  expect_equal(out, new_access)
  expect_equal(.token_cache$refresh, "refresh-abc")  # preserved, not wiped to NULL
})

test_that("Workbench managed OAuth is tried, independent of isAvailable()", {
  # findOAuthIntegration()/getOAuthCredentials() must be attempted even
  # when rstudioapi::isAvailable() would report FALSE (e.g. inside a
  # `quarto render` child process) -- they gate themselves on a genuine
  # Workbench session internally, not on isAvailable().
  withr::local_envvar(VIYA_TOKEN = "")
  local_token_cache()
  tok <- mk_jwt(as.numeric(Sys.time()) + 36000)
  testthat::local_mocked_bindings(
    isAvailable = function(...) FALSE,
    findOAuthIntegration = function(...) list(guid = "guid-1"),
    getOAuthCredentials = function(...) list(access_token = tok),
    .package = "rstudioapi")

  expect_equal(viya_token(), tok)
  expect_equal(.token_cache$tok, tok)
})

test_that("a non-Workbench RStudio/Positron session falls through instead of erroring", {
  # findOAuthIntegration() itself asserts a real Workbench session and
  # throws otherwise (e.g. plain RStudio Desktop, a local Positron
  # session with no Workbench attached) -- viya_token() must catch that
  # and fall through to its next resolution step, not propagate the error.
  withr::local_envvar(VIYA_TOKEN = "")
  local_token_cache()
  testthat::local_mocked_bindings(
    findOAuthIntegration = function(...)
      stop("assertWorkbenchSession(): only available within Posit Workbench sessions"),
    .package = "rstudioapi")

  expect_error(viya_token(), "viya_login\\(\\)")
})

test_that("a clear error is thrown when nothing is available", {
  withr::local_envvar(VIYA_TOKEN = "", POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "")
  local_token_cache()
  # Not mocking findOAuthIntegration(): the real rstudioapi function
  # should fail fast on its own internal Workbench-session check (no
  # network call) and viya_token() should catch that and fall through.
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
    findOAuthIntegration = function(...) list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token"),
    .package = "rstudioapi")

  expect_equal(viya_config()$url, "https://viya.pcluster.soleng.posit.it")
})

test_that("viya_config() prefers an explicitly configured URL over auto-detection", {
  withr::local_envvar(VIYA_URL = "")
  withr::local_options(viyar.url = NULL)
  testthat::local_mocked_bindings(
    findOAuthIntegration = function(...) list(
      issuer = "https://auto-detected.example.com/SASLogon/oauth/token"),
    .package = "rstudioapi")

  viya_config(url = "https://explicit.example.com")
  expect_equal(viya_config()$url, "https://explicit.example.com")
})

test_that("viya_config() auto-detection works even when isAvailable() reports FALSE", {
  # Regression test for the quarto-render bug: auto-detection must not
  # depend on rstudioapi::isAvailable() at all.
  withr::local_envvar(VIYA_URL = "")
  withr::local_options(viyar.url = NULL)
  testthat::local_mocked_bindings(
    isAvailable = function(...) FALSE,
    findOAuthIntegration = function(...) list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token"),
    .package = "rstudioapi")

  expect_equal(viya_config()$url, "https://viya.pcluster.soleng.posit.it")
})

test_that(".viya_in_workbench_session() checks POSIT_PRODUCT and RS_SERVER_ADDRESS", {
  withr::local_envvar(POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "")
  expect_false(.viya_in_workbench_session())

  withr::local_envvar(POSIT_PRODUCT = "WORKBENCH")
  expect_true(.viya_in_workbench_session())

  withr::local_envvar(POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "https://workbench.example.com")
  expect_true(.viya_in_workbench_session())
})

test_that(".viya_no_url_error() adds a hint when not in a Workbench session", {
  # Found live: quarto render (and a notebook's own execution kernel) run
  # in a separate R process, but env vars are inherited by any subprocess,
  # so this check -- unlike rstudioapi::isAvailable() -- still correctly
  # reports "in Workbench" for those cases. The hint is only for when
  # there's truly no Workbench session at all.
  withr::local_envvar(POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "")
  expect_match(.viya_no_url_error(), "Posit Workbench session")
  expect_match(.viya_no_url_error(), "No Viya URL configured")
})

test_that(".viya_no_url_error() omits the hint when inside a Workbench session", {
  withr::local_envvar(POSIT_PRODUCT = "WORKBENCH")
  expect_no_match(.viya_no_url_error(), "Posit Workbench session")
  expect_match(.viya_no_url_error(), "No Viya URL configured")
})

test_that("viya_session() surfaces the hint when no URL is configured outside Workbench", {
  withr::local_envvar(VIYA_URL = "", POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "")
  withr::local_options(viyar.url = NULL)
  expect_error(viya_session(token = "t"), "Posit Workbench session")
})

test_that("viya_login() surfaces the hint when no URL is configured outside Workbench", {
  withr::local_envvar(VIYA_URL = "", POSIT_PRODUCT = "", RS_SERVER_ADDRESS = "")
  withr::local_options(viyar.url = NULL)
  expect_error(viya_login(), "Posit Workbench session")
})
