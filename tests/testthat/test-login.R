test_that(".pkce_challenge matches the RFC 7636 Appendix B test vector", {
  verifier <- "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  expect_equal(.pkce_challenge(verifier),
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
})

test_that(".pkce_verifier generates a spec-compliant random verifier", {
  v <- .pkce_verifier()
  expect_true(nchar(v) >= 43 && nchar(v) <= 128)
  expect_match(v, "^[A-Za-z0-9._~-]+$")
  expect_false(identical(.pkce_verifier(), .pkce_verifier()))
})

test_that(".parse_auth_code accepts a bare code", {
  expect_equal(.parse_auth_code("  abc123  "), "abc123")
})

test_that(".parse_auth_code extracts code= from a full redirect URL", {
  expect_equal(
    .parse_auth_code("https://example.com/cb?code=abc123&state=xyz"),
    "abc123")
  expect_equal(
    .parse_auth_code("https://example.com/cb?state=xyz&code=a%2Fb%3Dc"),
    "a/b=c")
})

test_that(".parse_auth_code surfaces an OAuth error param clearly", {
  expect_error(
    .parse_auth_code(paste0("https://example.com/cb?error=access_denied",
                            "&error_description=User%20cancelled")),
    "User cancelled")
})

test_that(".parse_auth_code errors when no code is present", {
  expect_error(.parse_auth_code("https://example.com/cb?state=xyz"),
               "No code parameter")
  expect_error(.parse_auth_code(""), "No authorization code")
})

test_that(".viya_token_exchange posts a form body and returns parsed JSON", {
  seen <- NULL
  resp <- httr2::response_json(status = 200, body = list(
    access_token = "AT", refresh_token = "RT", token_type = "bearer"))
  httr2::local_mocked_responses(function(req) {
    seen <<- req
    resp
  })
  out <- .viya_token_exchange("https://viya.example.com", list(
    grant_type = "authorization_code", client_id = "vscode-positron",
    code = "abc123", code_verifier = "verifier-value"))

  expect_equal(seen$url, "https://viya.example.com/SASLogon/oauth/token")
  expect_equal(as.character(seen$body$data$grant_type), "authorization_code")
  expect_equal(as.character(seen$body$data$code), "abc123")
  expect_equal(out$access_token, "AT")
  expect_equal(out$refresh_token, "RT")
})

test_that(".viya_token_exchange surfaces SASLogon's error_description", {
  resp <- httr2::response_json(status = 400, body = list(
    error = "invalid_grant", error_description = "Invalid authorization code"))
  httr2::local_mocked_responses(list(resp))
  expect_error(
    .viya_token_exchange("https://viya.example.com", list(grant_type = "x")),
    "Invalid authorization code")
})

test_that(".viya_token_exchange sets a 30-second timeout", {
  seen <- NULL
  resp <- httr2::response_json(status = 200, body = list(access_token = "AT"))
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })
  .viya_token_exchange("https://viya.example.com", list(grant_type = "x"))
  expect_equal(seen$options$timeout, 30000)
})

test_that(".viya_cache_token populates the token cache from a token response", {
  local_token_cache()
  exp_time <- as.numeric(Sys.time()) + 36000
  payload <- as.character(jsonlite::toJSON(list(exp = exp_time), auto_unbox = TRUE))
  seg <- chartr("+/", "-_", sub("=+$", "", openssl::base64_encode(charToRaw(payload))))
  tok <- paste("h", seg, "s", sep = ".")

  out <- .viya_cache_token(list(access_token = tok, refresh_token = "RT"),
                            client_id = "vscode-positron")
  expect_equal(out, tok)
  expect_equal(.token_cache$tok, tok)
  expect_equal(.token_cache$refresh, "RT")
  expect_equal(.token_cache$client_id, "vscode-positron")
  expect_equal(as.numeric(.token_cache$exp), exp_time)
})
