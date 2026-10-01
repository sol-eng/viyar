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

.with_pandoc_to <- function(to, expr) {
  old <- knitr::opts_knit$get("rmarkdown.pandoc.to")
  knitr::opts_knit$set(rmarkdown.pandoc.to = to)
  on.exit(knitr::opts_knit$set(rmarkdown.pandoc.to = old), add = TRUE)
  force(expr)
}

test_that(".viya_sas_render() echoes the code as a highlighted sourceCode block and shows the log as a fenced block by default, for an HTML target", {
  skip_if_not_installed("knitr")
  out <- .with_pandoc_to("html", .viya_sas_render(list(echo = TRUE), "proc means; run;",
                          list(state = "completed", log = c("NOTE: done"))))

  expect_s3_class(out, "knit_asis")
  expect_true(grepl('<pre class="sourceCode sas">', out, fixed = TRUE))
  expect_true(grepl('<span class="kw">proc</span>', out, fixed = TRUE))
  expect_true(grepl("NOTE: done", out, fixed = TRUE))
})

test_that(".viya_sas_render() falls back to a plain fenced code block for a non-HTML target, since raw HTML is silently dropped by pandoc's non-HTML writers", {
  skip_if_not_installed("knitr")
  out <- .with_pandoc_to("latex", .viya_sas_render(list(echo = TRUE), "proc means; run;",
                          list(state = "completed")))

  expect_true(grepl("```sas\nproc means; run;\n```", out, fixed = TRUE))
  expect_false(grepl('class="sourceCode sas"', out, fixed = TRUE))
})

test_that(".viya_sas_render() falls back to the same plain fenced code block when the target is unknown (not running inside an actual pandoc render)", {
  skip_if_not_installed("knitr")
  out <- .with_pandoc_to(NULL, .viya_sas_render(list(echo = TRUE), "proc means; run;",
                          list(state = "completed")))

  expect_true(grepl("```sas\nproc means; run;\n```", out, fixed = TRUE))
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

test_that(".viya_sas_render() keeps the emitted iframe tag on one physical line so a blank line inside real ODS html can't end pandoc's raw-HTML-block early", {
  skip_if_not_installed("knitr")
  # Real ODS HTML5 output is blank-line-heavy. asis_output() text is parsed
  # by pandoc as CommonMark, whose raw-HTML-block rule ends a block at the
  # first blank line -- even one sitting inside our srcdoc attribute value,
  # where a browser wouldn't care. If a blank line survives inside the
  # emitted <iframe> tag, pandoc truncates the block there and splices
  # everything after it into the surrounding page as loose HTML/text --
  # exactly the leak this feature exists to prevent.
  ods_with_blank_line <- paste0(
    "<html><head>\n<style>\n.c { text-align: center }\n</style></head>\n",
    "\n<body><p>hi</p></body></html>")

  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;",
                          list(state = "completed", html = c(Print = ods_with_blank_line)))

  iframe_tag <- regmatches(out, regexpr("<iframe.*</iframe>", out))
  expect_false(grepl("\n[ \t]*\n", iframe_tag))
})

test_that(".viya_sas_highlight() marks step-boundary/statement keywords with the pandoc 'kw' class", {
  out <- .viya_sas_highlight("data x; set y; run;")
  expect_true(grepl('<span class="kw">data</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="kw">set</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="kw">run</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks control-flow statements with the pandoc 'cf' class", {
  out <- .viya_sas_highlight("if x then y; else z;")
  expect_true(grepl('<span class="cf">if</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="cf">then</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="cf">else</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks procedure names with the pandoc 'ot' class, distinct from step keywords", {
  out <- .viya_sas_highlight("proc means data=sashelp.class; run;")
  expect_true(grepl('<span class="kw">proc</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="ot">means</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks ODS statements: 'ods'/'close' as keywords, the destination name as a procedure-like token", {
  out <- .viya_sas_highlight("ods html5; ods html5 close;")
  expect_true(grepl('<span class="kw">ods</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="ot">html5</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="kw">close</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks both comment styles with the pandoc 'co' class", {
  out <- .viya_sas_highlight("* a line comment; data x; /* a block\ncomment */ run;")
  expect_true(grepl('<span class="co">* a line comment;</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="co">/* a block', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks quoted strings with the pandoc 'st' class", {
  out <- .viya_sas_highlight('x = "hello"; y = \'world\';')
  expect_true(grepl('<span class="st">&quot;hello&quot;</span>', out, fixed = TRUE))
  expect_true(grepl("<span class=\"st\">'world'</span>", out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks macro variables 'va' and macro statements/calls 'fu'", {
  out <- .viya_sas_highlight("%put &sysdate;")
  expect_true(grepl('<span class="fu">%put</span>', out, fixed = TRUE))
  expect_true(grepl('<span class="va">&amp;sysdate</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() marks numeric literals with the pandoc 'dv' class", {
  out <- .viya_sas_highlight("x = 42;")
  expect_true(grepl('<span class="dv">42</span>', out, fixed = TRUE))
})

test_that(".viya_sas_highlight() HTML-escapes stray angle brackets and ampersands outside of any token", {
  out <- .viya_sas_highlight("aa < bb & cc > dd;")
  expect_true(grepl("aa &lt; bb &amp; cc &gt; dd", out, fixed = TRUE))
})

test_that(".viya_sas_highlight() never leaves a blank line in its output, so pandoc's raw-HTML-block can't end early", {
  out <- .viya_sas_highlight("data x;\n\nrun;")
  expect_false(grepl("\n[ \t]*\n", out))
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

  out <- .with_pandoc_to("html", .viya_sas_engine(options))

  expect_true(grepl("<html>Alfred</html>", out, fixed = TRUE))
  expect_true(grepl('class="sourceCode sas"', out, fixed = TRUE))
})

test_that(".viya_sas_engine() honors eval = FALSE and never submits", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_engine(list(eval = FALSE, code = "proc means; run;",
                               echo = TRUE, engine = "sas"))
  expect_true(grepl("proc means; run;", out, fixed = TRUE))
})

test_that(".viya_sas_parse_libref_table() splits 'lib.table', defaulting the libref to 'work' when omitted", {
  expect_equal(.viya_sas_parse_libref_table("work.result"), list(libref = "work", table = "result"))
  expect_equal(.viya_sas_parse_libref_table("result"), list(libref = "work", table = "result"))
  expect_equal(.viya_sas_parse_libref_table("PUBLIC.HEART"), list(libref = "PUBLIC", table = "HEART"))
})

test_that(".viya_sas_push_inputs() writes each named R data.frame to WORK.<NAME> before the chunk's code runs", {
  h <- .quarto_handle()
  assign("push_test_df", data.frame(x = 1:2), envir = .GlobalEnv)
  withr::defer(rm("push_test_df", envir = .GlobalEnv))

  seen <- list()
  testthat::local_mocked_bindings(
    viya_write = function(h, df, libref, table, ...) {
      seen[[length(seen) + 1]] <<- list(df = df, libref = libref, table = table)
      invisible(NULL)
    })

  .viya_sas_push_inputs(h, "push_test_df")

  expect_length(seen, 1)
  expect_equal(seen[[1]]$libref, "WORK")
  expect_equal(seen[[1]]$table, "push_test_df")
  expect_equal(seen[[1]]$df, data.frame(x = 1:2))
})

test_that(".viya_sas_push_inputs() writes to an explicit libref when sas.input uses a 'libref.name' spec", {
  h <- .quarto_handle()
  assign("push_test_df2", data.frame(x = 1), envir = .GlobalEnv)
  withr::defer(rm("push_test_df2", envir = .GlobalEnv))

  seen <- list()
  testthat::local_mocked_bindings(
    viya_write = function(h, df, libref, table, ...) {
      seen[[length(seen) + 1]] <<- list(libref = libref, table = table)
      invisible(NULL)
    })

  .viya_sas_push_inputs(h, "mylib.push_test_df2")

  expect_length(seen, 1)
  expect_equal(seen[[1]]$libref, "MYLIB")
  expect_equal(seen[[1]]$table, "push_test_df2")
})

test_that(".viya_sas_push_inputs() errors clearly when the named object doesn't exist", {
  h <- .quarto_handle()
  expect_error(.viya_sas_push_inputs(h, "definitely_not_bound_anywhere"),
              "does not name any object")
})

test_that(".viya_sas_push_inputs() errors clearly when the named object isn't a data.frame", {
  h <- .quarto_handle()
  assign("push_test_not_df", list(x = 1), envir = .GlobalEnv)
  withr::defer(rm("push_test_not_df", envir = .GlobalEnv))

  expect_error(.viya_sas_push_inputs(h, "push_test_not_df"),
              "does not resolve to a data.frame")
})

test_that(".viya_sas_pull_output() reads the named SAS dataset and assigns it into the knit environment", {
  h <- .quarto_handle()
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(y = libref, z = table))

  .viya_sas_pull_output(h, "work.result", NULL)
  withr::defer(rm("result", envir = .GlobalEnv))

  expect_equal(get("result", envir = .GlobalEnv), data.frame(y = "work", z = "result"))
})

test_that(".viya_sas_pull_output() uses an explicit sas.output_var name over the table's own name", {
  h <- .quarto_handle()
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(n = 1))

  .viya_sas_pull_output(h, "work.result", "my_df")
  withr::defer(rm("my_df", envir = .GlobalEnv))

  expect_equal(get("my_df", envir = .GlobalEnv), data.frame(n = 1))
})

test_that(".viya_sas_pull_output() passes an explicit max_rows through to viya_read()", {
  h <- .quarto_handle()
  seen_max_rows <- "not set"
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, max_rows = "not set", ...) {
      seen_max_rows <<- max_rows
      data.frame()
    })

  .viya_sas_pull_output(h, "work.result", "capped_df", max_rows = 5)
  withr::defer(rm("capped_df", envir = .GlobalEnv))

  expect_equal(seen_max_rows, 5)
})

test_that(".viya_sas_pull_output() leaves max_rows at viya_read()'s own default when not given", {
  h <- .quarto_handle()
  seen_max_rows <- "not set"
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, max_rows = "not set", ...) {
      seen_max_rows <<- max_rows
      data.frame()
    })

  .viya_sas_pull_output(h, "work.result", "uncapped_df")
  withr::defer(rm("uncapped_df", envir = .GlobalEnv))

  expect_equal(seen_max_rows, "not set")
})

test_that(".viya_sas_pull_output() pulls every table in a multi-value sas.output_data, defaulting each var to its own table name", {
  h <- .quarto_handle()
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(table = table))

  .viya_sas_pull_output(h, c("work.result1", "work.result2"), NULL)
  withr::defer(rm("result1", "result2", envir = .GlobalEnv))

  expect_equal(get("result1", envir = .GlobalEnv), data.frame(table = "result1"))
  expect_equal(get("result2", envir = .GlobalEnv), data.frame(table = "result2"))
})

test_that(".viya_sas_pull_output() matches a multi-value sas.output_var to sas.output_data by position", {
  h <- .quarto_handle()
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(table = table))

  .viya_sas_pull_output(h, c("work.result1", "work.result2"), c("df_a", "df_b"))
  withr::defer(rm("df_a", "df_b", envir = .GlobalEnv))

  expect_equal(get("df_a", envir = .GlobalEnv), data.frame(table = "result1"))
  expect_equal(get("df_b", envir = .GlobalEnv), data.frame(table = "result2"))
})

test_that(".viya_sas_pull_output() errors clearly when sas.output_var's length doesn't match sas.output_data's", {
  h <- .quarto_handle()
  expect_error(
    .viya_sas_pull_output(h, c("work.result1", "work.result2"), "just_one_name"),
    "sas.output_var.*sas.output_data", fixed = FALSE)
})

test_that(".viya_sas_engine() pushes sas.input data frames before submitting the code", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_push_handle", h, envir = .GlobalEnv)
  assign("engine_push_df", data.frame(a = 1), envir = .GlobalEnv)
  withr::defer(rm("engine_push_handle", "engine_push_df", envir = .GlobalEnv))

  seen_write <- list()
  testthat::local_mocked_bindings(
    viya_write = function(h, df, libref, table, ...) {
      seen_write[[length(seen_write) + 1]] <<- list(libref = libref, table = table)
      invisible(NULL)
    })

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(seen, state = "completed"))

  options <- list(session = "engine_push_handle", sas.input = "engine_push_df",
                  code = "proc print data=work.engine_push_df; run;",
                  echo = FALSE, viya.output = "log")

  .viya_sas_engine(options)

  expect_length(seen_write, 1)
  expect_equal(seen_write[[1]]$table, "engine_push_df")
})

test_that(".viya_sas_engine() pulls sas.output_data into sas.output_var after the code runs successfully", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_pull_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_pull_handle", envir = .GlobalEnv))

  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(pulled = TRUE))

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(seen, state = "completed"))

  options <- list(session = "engine_pull_handle",
                  sas.output_data = "work.result", sas.output_var = "pulled_df",
                  code = "data work.result; x = 1; run;",
                  echo = FALSE, viya.output = "log")

  .viya_sas_engine(options)
  withr::defer(rm("pulled_df", envir = .GlobalEnv))

  expect_equal(get("pulled_df", envir = .GlobalEnv), data.frame(pulled = TRUE))
})

test_that(".viya_sas_engine() pulls multiple sas.output_data tables into their matching sas.output_var names", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_multi_pull_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_multi_pull_handle", envir = .GlobalEnv))

  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) data.frame(table = table))

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(seen, state = "completed"))

  options <- list(session = "engine_multi_pull_handle",
                  sas.output_data = c("work.result1", "work.result2"),
                  sas.output_var = c("multi_a", "multi_b"),
                  code = "data work.result1 work.result2; x = 1; run;",
                  echo = FALSE, viya.output = "log")

  .viya_sas_engine(options)
  withr::defer(rm("multi_a", "multi_b", envir = .GlobalEnv))

  expect_equal(get("multi_a", envir = .GlobalEnv), data.frame(table = "result1"))
  expect_equal(get("multi_b", envir = .GlobalEnv), data.frame(table = "result2"))
})

test_that(".viya_sas_engine() threads sas.output_max_rows through to the pull", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_max_rows_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_max_rows_handle", envir = .GlobalEnv))

  seen_max_rows <- "not set"
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, max_rows = "not set", ...) {
      seen_max_rows <<- max_rows
      data.frame(n = 1)
    })

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(seen, state = "completed"))

  options <- list(session = "engine_max_rows_handle",
                  sas.output_data = "work.result", sas.output_var = "capped_df",
                  sas.output_max_rows = 10,
                  code = "data work.result; x = 1; run;",
                  echo = FALSE, viya.output = "log")

  .viya_sas_engine(options)
  withr::defer(rm("capped_df", envir = .GlobalEnv))

  expect_equal(seen_max_rows, 10)
})

test_that(".viya_sas_engine() skips the sas.output_data pull when the job didn't complete", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_skip_pull_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_skip_pull_handle", envir = .GlobalEnv))

  read_called <- FALSE
  testthat::local_mocked_bindings(
    viya_read = function(h, libref, table, ...) {
      read_called <<- TRUE
      data.frame()
    })

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(seen, state = "error"))

  options <- list(session = "engine_skip_pull_handle",
                  sas.output_data = "work.result", sas.output_var = "skipped_df",
                  viya.error = TRUE,
                  code = "data work.result; x = 1/0; run;",
                  echo = FALSE, viya.output = "log")

  .viya_sas_engine(options)

  expect_false(read_called)
  expect_false(exists("skipped_df", envir = .GlobalEnv))
})

test_that("the sas knitr engine is registered when the package loads and knitr is available", {
  skip_if_not_installed("knitr")
  expect_identical(knitr::knit_engines$get("sas"), .viya_sas_engine)
})
