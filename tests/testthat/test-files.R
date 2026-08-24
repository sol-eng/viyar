test_that("viya_create_folder creates missing intermediate folders one level at a time", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  # /Public exists; /Public/Reports and /Public/Reports/2026 don't yet.
  resp_public_ok <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_reports_404 <- httr2::response(status = 404)
  resp_reports_created <- httr2::response_json(status = 201, body = list(id = "reports-id", name = "Reports"))
  resp_2026_404 <- httr2::response(status = 404)
  resp_2026_created <- httr2::response_json(status = 201, body = list(id = "2026-id", name = "2026"))

  seq <- list(resp_public_ok, resp_reports_404, resp_reports_created,
              resp_2026_404, resp_2026_created)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_create_folder(h, "/Public/Reports/2026")
  expect_equal(out$id, "2026-id")
  expect_equal(i, 5)
})

test_that("viya_create_folder is idempotent when every segment already exists", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_public_ok <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_reports_ok <- httr2::response_json(status = 200, body = list(id = "reports-id", name = "Reports"))

  seq <- list(resp_public_ok, resp_reports_ok)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_create_folder(h, "/Public/Reports")
  expect_equal(out$id, "reports-id")
  expect_equal(i, 2)  # only the two existence checks -- no create calls
})

test_that("viya_create_folder validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_create_folder(bad_h, "/Public/x"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_create_folder(h, ""))
})
