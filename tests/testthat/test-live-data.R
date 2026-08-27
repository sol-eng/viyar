test_that("viya_write then viya_read round-trips a data.frame", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  df <- data.frame(id = 1:3, val = c(1.5, 2.5, 3.5))
  viya_write(h, df, "WORK", "VIYAR_TEST_RT")
  back <- viya_read(h, "WORK", "VIYAR_TEST_RT")

  # PROC IMPORT preserves the staged CSV header's exact case (`id`, `val`)
  # rather than uppercasing it -- confirmed live against a real cluster,
  # not assumed.
  expect_equal(nrow(back), 3)
  expect_equal(sort(back$id), 1:3)
})

test_that("viya_read returns stored values, not their display format", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  # Each format here defeated the old formatted read in a different way:
  # `10.4` truncated to four decimals, `date9.` and `dollar12.2` produced
  # display strings that `as.numeric()` turned into NA.
  viya_submit(h, paste(
    "data work.viyar_fmt;",
    "  x = 60.26964309; format x 10.4;",
    "  d = '01JAN2020'd; format d date9.;",
    "  pay = 1234.5; format pay dollar12.2;",
    "  gone = .; format gone dollar12.2;",
    "run;", sep = "\n"))

  df <- viya_read(h, "WORK", "VIYAR_FMT", dates = "d")

  # A failure on `x` specifically -- right value, too few digits -- points
  # at the session's DECIMALCONV option rather than at this fix; SAS's docs
  # name DECIMALCONV=STDIEEE as the setting for full significant digits.
  expect_equal(df$x, 60.26964309)
  expect_equal(df$d, as.Date("2020-01-01"))
  expect_equal(df$pay, 1234.5)
  expect_true(is.na(df$gone))
})

test_that("viya_read(dates =) reads a date column from a real SAS table", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  # SASHELP.STOCKS's date column carries a MONYY7. format, so it is a
  # genuine formatted-date column rather than one this test created.
  stocks <- viya_read(h, "SASHELP", "STOCKS", dates = "Date", max_rows = 10)
  d <- stocks[[grep("^date$", names(stocks), ignore.case = TRUE)[1]]]

  expect_s3_class(d, "Date")
  expect_false(anyNA(d))
  expect_true(all(d > as.Date("1980-01-01")))
})

test_that("viya_upload then viya_download round-trips a file", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  # A fixed filename collides (HTTP 409) on a second run against the same
  # cluster -- Files doesn't support overwrite-on-upload -- so use a
  # unique name per run and clean up afterward, confirmed live.
  fname <- paste0("viyar_live_test_", as.integer(Sys.time()), ".txt")
  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar live test", tmp_up)
  viya_upload(h, tmp_up, "/Public", name = fname)
  on.exit(tryCatch(viya_delete_file(h, paste0("/Public/", fname)),
                   error = function(e) NULL), add = TRUE)

  tmp_down <- tempfile(fileext = ".txt")
  viya_download(h, paste0("/Public/", fname), tmp_down)
  expect_equal(readLines(tmp_down), "viyar live test")
})
