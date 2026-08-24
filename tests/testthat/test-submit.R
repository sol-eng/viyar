test_that("viya_datasets() falls back to dictionary.tables and extracts lowercase memname", {
  # System libraries like SASHELP aren't enumerated by the Compute data
  # service, so viya_datasets() falls back to a PROC SQL query against
  # dictionary.tables. That query's SELECT list is written in lowercase
  # (memname, memtype, nobs), and SAS preserves that exact case rather
  # than uppercasing it -- confirmed live against a real cluster, where
  # viya_datasets() was found returning NULL because it accessed
  # $MEMNAME (uppercase) on a data.frame whose actual column was
  # $memname (lowercase).
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_data_empty  <- httr2::response_json(status = 200, body = list(items = list()))
  resp_job_created <- httr2::response_json(status = 201, body = list(id = "job1"))
  resp_job_state   <- httr2::response(status = 200, body = charToRaw("completed"))
  resp_job_log     <- httr2::response_json(status = 200, body = list(items = list()))
  resp_columns     <- httr2::response_json(status = 200, body = list(items = list(
    list(name = "memname", type = "char"),
    list(name = "memtype", type = "char"),
    list(name = "nobs", type = "num"))))
  resp_rows <- httr2::response_json(status = 200, body = list(items = list(
    list(cells = list("AACOMP", "DATA", 2020)))))

  seq <- list(resp_data_empty, resp_job_created, resp_job_state, resp_job_log,
              resp_columns, resp_rows)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_datasets(h, "SASHELP")
  expect_equal(out, "AACOMP")
})

test_that("viya_members() returns lowercase memname/memtype/nobs columns", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_job_created <- httr2::response_json(status = 201, body = list(id = "job1"))
  resp_job_state   <- httr2::response(status = 200, body = charToRaw("completed"))
  resp_job_log     <- httr2::response_json(status = 200, body = list(items = list()))
  resp_columns     <- httr2::response_json(status = 200, body = list(items = list(
    list(name = "memname", type = "char"),
    list(name = "memtype", type = "char"),
    list(name = "nobs", type = "num"))))
  resp_rows <- httr2::response_json(status = 200, body = list(items = list(
    list(cells = list("HEART", "DATA", 5209)))))

  seq <- list(resp_job_created, resp_job_state, resp_job_log, resp_columns, resp_rows)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_members(h, "SASHELP")
  expect_equal(names(out), c("memname", "memtype", "nobs"))
  expect_equal(out$memname, "HEART")
})
