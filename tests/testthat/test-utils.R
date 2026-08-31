test_that(".viya_is_transient flags only 429/503 (matching httr2's own safe default)", {
  expect_true(.viya_is_transient(httr2::response(status = 429)))
  expect_true(.viya_is_transient(httr2::response(status = 503)))
  expect_false(.viya_is_transient(httr2::response(status = 500)))
  expect_false(.viya_is_transient(httr2::response(status = 502)))
  expect_false(.viya_is_transient(httr2::response(status = 504)))
  expect_false(.viya_is_transient(httr2::response(status = 200)))
  expect_false(.viya_is_transient(httr2::response(status = 404)))
})

test_that(".viya_req wires a 3-try retry policy", {
  req <- .viya_req(list(token = "t", base = "https://viya.example.com"), "/x")
  expect_equal(req$policies$retry_max_tries, 3)
})

test_that(".viya_url joins with exactly one slash whichever side carries it", {
  # A VIYA_URL env var ending in "/" produced "//compute/contexts?limit=100",
  # which Viya 404s ("There is no handler defined for the path"). Neither
  # side of the join is guaranteed clean: the base comes from user/env
  # input, and some paths are hrefs the service hands back.
  expect_equal(.viya_url("https://x.example", "/compute/contexts"),
               "https://x.example/compute/contexts")
  expect_equal(.viya_url("https://x.example/", "/compute/contexts"),
               "https://x.example/compute/contexts")
  expect_equal(.viya_url("https://x.example", "compute/contexts"),
               "https://x.example/compute/contexts")
  expect_equal(.viya_url("https://x.example/", "compute/contexts"),
               "https://x.example/compute/contexts")
  expect_equal(.viya_url("https://x.example///", "///compute/contexts"),
               "https://x.example/compute/contexts")
})

test_that(".viya_url preserves a base URL's own path prefix", {
  expect_equal(.viya_url("https://x.example/viya/", "/compute/contexts"),
               "https://x.example/viya/compute/contexts")
})

test_that("a trailing slash on `url` builds the same request as none", {
  seen <- list()
  resp <- httr2::response_json(status = 200, body = list(items = list()))
  httr2::local_mocked_responses(function(req) {
    seen[[length(seen) + 1L]] <<- req
    resp
  })
  for (u in c("https://x.example", "https://x.example/")) {
    viya_contexts(token = "t", url = u)
  }
  expect_equal(seen[[1]]$url, "https://x.example/compute/contexts?limit=100")
  # Asserting both forms agree, rather than only the trailing-slash one,
  # so a fix that normalized the already-clean form into breakage fails here.
  expect_equal(seen[[2]]$url, seen[[1]]$url)
})

test_that(".viya_req surfaces Viya's JSON error message and remediation", {
  resp <- httr2::response_json(
    status = 404,
    body = list(message = "Context 'Bogus' not found.",
                remediation = "Call viya_contexts() to list valid names."))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/compute/contexts/bogus") |> httr2::req_perform(),
                  error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "Context 'Bogus' not found", fixed = TRUE)
  expect_match(conditionMessage(err), "Call viya_contexts", fixed = TRUE)
})

test_that(".viya_req falls back to the default httr2 message for non-JSON errors", {
  resp <- httr2::response(status = 500, body = charToRaw("upstream blew up"))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/x") |> httr2::req_perform(), error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "HTTP 500")
})

test_that(".viya_req surfaces the error message for a vendor +json content type", {
  # SAS Viya REST services commonly return application/vnd.sas.error+json
  # rather than bare application/json.
  resp <- httr2::response(
    status = 400,
    headers = list("Content-Type" = "application/vnd.sas.error+json"),
    body = charToRaw(as.character(jsonlite::toJSON(
      list(message = "Invalid caslib name.", remediation = "Use viya_caslib_tables() to list valid names."),
      auto_unbox = TRUE))))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/x") |> httr2::req_perform(), error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "Invalid caslib name", fixed = TRUE)
  expect_match(conditionMessage(err), "Use viya_caslib_tables", fixed = TRUE)
})

test_that(".viya_error_body ignores an errors array when there's no top-level message (no partial match)", {
  resp <- httr2::response_json(status = 403, body = list(errors = list(list(code = 1))))
  expect_null(.viya_error_body(resp))
})

test_that(".viya_error_body returns NULL for a JSON body with no recognized error fields", {
  resp <- httr2::response_json(status = 500, body = list(foo = "bar"))
  expect_null(.viya_error_body(resp))
})

test_that("viya_reachable() returns FALSE for an unreachable host", {
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1))
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1, insecure = TRUE))
})

test_that("viya_reachable()'s insecure default reads the viyar.insecure option", {
  withr::local_options(viyar.insecure = TRUE)
  expect_true(eval(formals(viya_reachable)$insecure))
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1))

  withr::local_options(viyar.insecure = NULL)
  expect_false(eval(formals(viya_reachable)$insecure))
})

mk_jwt <- function(exp) {
  payload <- as.character(jsonlite::toJSON(list(exp = exp), auto_unbox = TRUE))
  seg <- openssl::base64_encode(charToRaw(payload))
  seg <- chartr("+/", "-_", sub("=+$", "", seg))
  paste("header", seg, "sig", sep = ".")
}

test_that(".jwt_exp decodes the exp claim from a base64url JWT payload", {
  target <- as.POSIXct(1893456003, origin = "1970-01-01", tz = "UTC")
  decoded <- .jwt_exp(mk_jwt(1893456003))
  expect_equal(as.numeric(decoded), as.numeric(target))
})

test_that(".jwt_exp returns NA for a non-JWT or malformed token", {
  expect_true(is.na(.jwt_exp("not-a-jwt")))
  expect_true(is.na(.jwt_exp("")))
})
