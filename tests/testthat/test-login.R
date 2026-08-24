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
