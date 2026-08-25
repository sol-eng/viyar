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

  # No file= on purpose: the compute server routes a fileref-less html5
  # destination to its results endpoint. Naming an explicit fileref writes
  # to the server's disk instead, and _tomods1 in particular does not exist
  # here -- that is SASPy's own fileref, and asking for it fails live with
  # "ERROR: No logical assign for filename _TOMODS1."
  r <- viya_submit(h, paste(
    "ods html5(id=viyar);",
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
