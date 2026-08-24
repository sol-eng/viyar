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

  # A fixed filename collides (HTTP 409) on a second run against the same
  # cluster -- Files doesn't support overwrite-on-upload -- so use a
  # unique name per run and clean up afterward, confirmed live.
  fname <- paste0("viyar_live_test_", as.integer(Sys.time()), ".txt")
  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar live test", tmp_up)
  up <- viya_upload(h, tmp_up, "/Public", name = fname)
  on.exit(tryCatch(
    .viya_req(h, paste0("/files/files/", up$id)) |>
      httr2::req_method("DELETE") |> httr2::req_perform(),
    error = function(e) NULL), add = TRUE)

  tmp_down <- tempfile(fileext = ".txt")
  viya_download(h, paste0("/Public/", fname), tmp_down)
  expect_equal(readLines(tmp_down), "viyar live test")
})
