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

test_that(".viya_resolve_session() looks up a string option as a variable name in the global env", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("test_quarto_handle", h, envir = .GlobalEnv)
  withr::defer(rm("test_quarto_handle", envir = .GlobalEnv))

  expect_identical(.viya_resolve_session("test_quarto_handle"), h)
})

test_that(".viya_resolve_session() accepts an already-resolved handle object", {
  h <- .quarto_handle()
  expect_identical(.viya_resolve_session(h), h)
})

test_that(".viya_resolve_session() errors clearly with no session option", {
  expect_error(.viya_resolve_session(NULL), "requires a `session`")
})

test_that(".viya_resolve_session() errors clearly when the name isn't a viyar handle", {
  skip_if_not_installed("knitr")
  assign("test_not_a_handle", list(x = 1), envir = .GlobalEnv)
  withr::defer(rm("test_not_a_handle", envir = .GlobalEnv))

  expect_error(.viya_resolve_session("test_not_a_handle"),
              "does not resolve to a viyar handle")
})

test_that(".viya_resolve_session() gives a clear error when the named object doesn't exist", {
  skip_if_not_installed("knitr")
  expect_error(.viya_resolve_session("definitely_not_bound_anywhere"),
              "does not name any object")
})

test_that(".viya_sas_render() echoes the code and shows the log as a fenced block by default", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = TRUE), "proc means; run;",
                          list(state = "completed", log = c("NOTE: done")))

  expect_s3_class(out, "knit_asis")
  expect_true(grepl("```sas\nproc means; run;\n```", out, fixed = TRUE))
  expect_true(grepl("NOTE: done", out, fixed = TRUE))
})

test_that(".viya_sas_render() omits the code block when echo is FALSE", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "proc means; run;",
                          list(state = "completed", log = c("NOTE: done")))

  expect_false(grepl("proc means; run;", out, fixed = TRUE))
})

test_that(".viya_sas_render() emits html output raw, without fencing", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;",
                          list(state = "completed", html = c(Print = "<p>hi</p>")))

  expect_true(grepl("<p>hi</p>", out, fixed = TRUE))
  expect_false(grepl("```", out, fixed = TRUE))
})

test_that(".viya_sas_render() isolates ODS html output in an iframe so its own <style> block can't leak into the surrounding page", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;", list(
    state = "completed",
    html = c(Print = "<html><head><style>H1 { text-align: center; }</style></head><body><p>hi</p></body></html>")))

  expect_true(grepl('<iframe[^>]+srcdoc="', out))
  expect_true(grepl("H1 { text-align: center; }", out, fixed = TRUE))
})

test_that(".viya_sas_render() escapes a double quote in ODS html so it can't break out of the iframe's srcdoc attribute", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;", list(
    state = "completed",
    html = c(Print = '<p class="a">hi</p>')))

  expect_true(grepl('<p class=&quot;a&quot;>hi</p>', out, fixed = TRUE))
  expect_false(grepl('<p class="a">hi</p>', out, fixed = TRUE))
})

test_that(".viya_sas_render() escapes a literal ampersand in ODS html for correct round-tripping through the srcdoc attribute", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;", list(
    state = "completed",
    html = c(Print = "<p>A &amp; B</p>")))

  expect_true(grepl("<p>A &amp;amp; B</p>", out, fixed = TRUE))
})

test_that(".viya_sas_engine() resolves the session, submits the code, and renders html output", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_test_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_test_handle", envir = .GlobalEnv))

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    results = list(list(id = "r1", name = "Print", type = "ODS", links = list(
      list(rel = "content",
           href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  options <- list(session = "engine_test_handle",
                  code = c("ods html5;", "proc print data=sashelp.class; run;"),
                  echo = TRUE, viya.output = "html")

  out <- .viya_sas_engine(options)

  expect_true(grepl("<html>Alfred</html>", out, fixed = TRUE))
  expect_true(grepl("```sas", out, fixed = TRUE))
})

test_that(".viya_sas_engine() honors eval = FALSE and never submits", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_engine(list(eval = FALSE, code = "proc means; run;",
                               echo = TRUE, engine = "sas"))
  expect_true(grepl("proc means; run;", out, fixed = TRUE))
})

test_that("the sas knitr engine is registered when the package loads and knitr is available", {
  skip_if_not_installed("knitr")
  expect_identical(knitr::knit_engines$get("sas"), .viya_sas_engine)
})
