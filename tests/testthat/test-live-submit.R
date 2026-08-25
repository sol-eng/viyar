test_that("viya_submit() returns listing text when the code opens ods listing", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  r <- viya_submit(h, paste(
    "ods listing;",
    "proc print data=sashelp.class(obs=3); run;",
    "ods listing close;", sep = "\n"),
    output = c("log", "listing"))

  expect_equal(r$state, "completed")
  expect_true(is.character(r$listing))
  expect_true(any(grepl("Alfred", r$listing)))
})

test_that("viya_submit() returns ODS HTML when the code opens an html5 destination", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  # _tomods1 is the fileref the Compute service exposes on its results
  # endpoint -- writing the html5 destination anywhere else produces a file
  # on the compute server's disk instead of a downloadable result.
  r <- viya_submit(h, paste(
    "ods html5(id=viyar) file=_tomods1 options(bitmap_mode='inline');",
    "proc print data=sashelp.class(obs=3); run;",
    "ods html5(id=viyar) close;", sep = "\n"),
    output = "html")

  expect_equal(r$state, "completed")
  expect_true(length(r$html) > 0)
  expect_true(any(grepl("Alfred", r$html)))
  expect_true(any(grepl("<table", r$html, ignore.case = TRUE)))
})

test_that("viya_submit() returns only the log by default", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  r <- viya_submit(h, "proc print data=sashelp.class(obs=3); run;")

  expect_equal(names(r), c("state", "log", "job_id"))
})
