.quarto_handle <- function() {
  structure(list(token = "t", session = "sess1", context = "ctx",
                 base = "https://viya.example.com"), class = "viyar")
}

# Mirrors .mock_submit() in test-submit.R: dispatches on the request URL,
# with a configurable job `state` for exercising the fail-fast branch.
.mock_quarto_submit <- function(seen, state = "completed", log = list(),
                                listing = NULL, results = NULL, content = NULL) {
  function(req) {
    seen$url <- c(seen$url, req$url)
    u <- req$url
    if (grepl("/jobs$", u))
      return(httr2::response_json(status = 201, body = list(id = "job1")))
    if (grepl("/state$", u))
      return(httr2::response(status = 200, body = charToRaw(state)))
    if (grepl("/log", u))
      return(httr2::response_json(status = 200, body = list(items = log)))
    if (grepl("/listing", u))
      return(httr2::response_json(status = 200, body = list(items = listing %||% list())))
    if (grepl("/results\\?", u))
      return(httr2::response_json(status = 200, body = list(items = results %||% list())))
    if (grepl("/results/", u))
      return(httr2::response(status = 200,
                             body = charToRaw(content[[sub(".*/results/", "", u)]])))
    stop("unexpected request: ", u)
  }
}

test_that("viya_submit_quarto() returns html output and drops the log when the job completes", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    results = list(list(id = "r1", name = "Print", type = "ODS", links = list(
      list(rel = "content",
           href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  r <- viya_submit_quarto(h, "ods html5; proc print data=sashelp.class; run;")

  expect_equal(r$state, "completed")
  expect_equal(unname(r$html), "<html>Alfred</html>")
  expect_null(r$log)
})

test_that("viya_submit_quarto() throws on a non-completed state, with the log tail in the message", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "error",
    log = list(list(line = "NOTE: start"), list(line = "ERROR: bad syntax"))))

  expect_error(
    viya_submit_quarto(h, "proc pint data=sashelp.class; run;"),
    "ERROR: bad syntax", fixed = TRUE)
})

test_that("viya_submit_quarto(error = TRUE) suppresses the throw and keeps the log for display", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "error",
    log = list(list(line = "ERROR: bad syntax"))))

  r <- viya_submit_quarto(h, "proc pint data=sashelp.class; run;", error = TRUE)

  expect_equal(r$state, "error")
  expect_equal(r$log, "ERROR: bad syntax")
})

test_that("viya_submit_quarto() keeps every explicitly requested output kind", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    listing = list(list(line = "Obs   Name"))))

  r <- viya_submit_quarto(h, "proc print; run;", output = c("log", "listing"))

  expect_equal(r$listing, "Obs   Name")
  expect_equal(r$log, character())
})

test_that("viya_submit_quarto() rejects an unknown output kind", {
  h <- .quarto_handle()
  expect_error(viya_submit_quarto(h, "run;", output = "pdf"), "should be one of")
})
