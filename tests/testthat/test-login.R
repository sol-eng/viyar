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
