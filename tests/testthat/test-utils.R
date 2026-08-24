test_that(".viya_is_transient flags retryable statuses only", {
  expect_true(.viya_is_transient(httr2::response(status = 429)))
  expect_true(.viya_is_transient(httr2::response(status = 500)))
  expect_true(.viya_is_transient(httr2::response(status = 502)))
  expect_true(.viya_is_transient(httr2::response(status = 503)))
  expect_true(.viya_is_transient(httr2::response(status = 504)))
  expect_false(.viya_is_transient(httr2::response(status = 200)))
  expect_false(.viya_is_transient(httr2::response(status = 404)))
})

test_that(".viya_req wires a 3-try retry policy", {
  req <- .viya_req(list(token = "t", base = "https://viya.example.com"), "/x")
  expect_equal(req$policies$retry_max_tries, 3)
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

test_that("viya_reachable() verifies TLS by default", {
  expect_false(isTRUE(formals(viya_reachable)$insecure))
})

test_that("viya_reachable() returns FALSE for an unreachable host", {
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1))
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1, insecure = TRUE))
})
