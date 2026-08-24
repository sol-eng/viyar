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

test_that("a clear error is thrown when nothing is available", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  expect_error(viya_token(), "viya_login\\(\\)")
})
