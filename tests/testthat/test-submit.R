.submit_handle <- function() {
  structure(list(token = "t", session = "sess1", context = "ctx",
                 base = "https://viya.example.com"), class = "viyar")
}

# Dispatches on the request URL rather than on call order, so a test can
# assert which endpoints were hit without also pinning the sequence they
# were hit in. Every URL is appended to `seen$url`.
.mock_submit <- function(seen, listing = NULL, results = NULL, content = NULL) {
  function(req) {
    seen$url <- c(seen$url, req$url)
    u <- req$url
    if (grepl("/jobs$", u))
      return(httr2::response_json(status = 201, body = list(id = "job1")))
    if (grepl("/state$", u))
      return(httr2::response(status = 200, body = charToRaw("completed")))
    if (grepl("/log", u))
      return(httr2::response_json(status = 200, body = list(items = list())))
    if (grepl("/listing", u))
      return(httr2::response_json(status = 200, body = list(items = listing)))
    if (grepl("/results\\?", u))
      return(httr2::response_json(status = 200, body = list(items = results)))
    if (grepl("/results/", u))
      return(httr2::response(status = 200,
                             body = charToRaw(content[[sub(".*/results/", "", u)]])))
    stop("unexpected request: ", u)
  }
}

test_that("viya_submit(output = 'listing') returns the job's listing lines", {
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(
    seen,
    listing = list(list(line = "Obs    Name", type = "title"),
                   list(line = "1      Alfred", type = "normal"))))

  r <- viya_submit(h, "proc print data=sashelp.class; run;",
                   output = c("log", "listing"))

  expect_equal(r$listing, c("Obs    Name", "1      Alfred"))
})

test_that("viya_submit(output = 'html') downloads the content of each ODS result", {
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(
    seen,
    results = list(
      list(id = "r1", name = "Print", type = "ODS", links = list(
        list(rel = "self",
             href = "/compute/sessions/sess1/jobs/job1/results/r1"),
        list(rel = "content",
             href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  r <- viya_submit(h, "proc print data=sashelp.class; run;", output = "html")

  expect_equal(r$html, c(Print = "<html>Alfred</html>"))
})

test_that("viya_submit(output = 'html') skips non-ODS results", {
  # The results collection also carries TABLE items describing datasets the
  # job created; those are not ODS output and have no HTML to download.
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(
    seen,
    results = list(
      list(id = "t1", name = "WORK.CLASS", type = "TABLE", links = list(
        list(rel = "self",
             href = "/compute/sessions/sess1/data/WORK/CLASS"))),
      list(id = "r1", name = "Print", type = "ODS", links = list(
        list(rel = "content",
             href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  r <- viya_submit(h, "proc print data=sashelp.class; run;", output = "html")

  expect_equal(names(r$html), "Print")
  expect_false(any(grepl("/data/WORK/CLASS", seen$url)))
})

test_that("viya_submit(output = 'html') falls back to the self link when there is no content link", {
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(
    seen,
    results = list(
      list(id = "r1", name = "Print", type = "ODS", links = list(
        list(rel = "self",
             href = "/compute/sessions/sess1/jobs/job1/results/r1")))),
    content = list("r1" = "<html>Alfred</html>")))

  r <- viya_submit(h, "proc print data=sashelp.class; run;", output = "html")

  expect_equal(unname(r$html), "<html>Alfred</html>")
})

test_that("viya_submit(output = 'html') errors clearly on an ODS result with no link", {
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(
    seen,
    results = list(list(id = "r1", name = "Print", type = "ODS"))))

  expect_error(viya_submit(h, "run;", output = "html"),
               "no downloadable link")
})

test_that("viya_submit() fetches nothing but the log by default", {
  # The whole point of `output` is that listing/results cost nothing when
  # they are not asked for -- this pins that no future edit starts
  # fetching output the caller never opted into.
  h <- .submit_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_submit(seen))

  r <- viya_submit(h, "proc print data=sashelp.class; run;")

  expect_equal(names(r), c("state", "log", "job_id"))
  expect_false(any(grepl("/listing|/results", seen$url)))
})

test_that("viya_submit() rejects an unknown output kind", {
  h <- .submit_handle()
  expect_error(viya_submit(h, "run;", output = "pdf"), "should be one of")
})

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

test_that("viya_members() reports the real library name, not the internal scratch table", {
  # viya_read()'s generic "read X x Y from WORK._VIYAR_MEMBERS" message
  # leaks the internal scratch-table implementation detail -- confirmed
  # confusing to a live user reading it after calling
  # viya_datasets(h, "SASHELP"). viya_members() should suppress that and
  # report against the library actually queried instead.
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

  expect_message(
    viya_members(h, "sashelp"),
    "read 1 member of SASHELP",
    fixed = TRUE
  )
})
