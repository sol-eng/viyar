test_that("viya_write then viya_read round-trips a data.frame", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  df <- data.frame(id = 1:3, val = c(1.5, 2.5, 3.5))
  viya_write(h, df, "WORK", "VIYAR_TEST_RT")
  back <- viya_read(h, "WORK", "VIYAR_TEST_RT")

  # PROC IMPORT preserves the staged CSV header's exact case (`id`, `val`)
  # rather than uppercasing it -- confirmed live against the soleng
  # cluster, not assumed.
  expect_equal(nrow(back), 3)
  expect_equal(sort(back$id), 1:3)
})

test_that("viya_upload then viya_download round-trips a file", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar live test", tmp_up)
  viya_upload(h, tmp_up, "/Public", name = "viyar_live_test.txt")

  tmp_down <- tempfile(fileext = ".txt")
  viya_download(h, "/Public/viyar_live_test.txt", tmp_down)
  expect_equal(readLines(tmp_down), "viyar live test")
})
