test_that("viya_create_folder creates nested SAS Content folders, idempotently", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  path <- paste0("/Public/viyar_live_test_", as.integer(Sys.time()))
  fld <- viya_create_folder(h, paste0(path, "/nested/deep"))
  on.exit(tryCatch({
    root <- .viya_folder(h, path)
    .viya_req(h, paste0("/folders/folders/", root$id, "?recursive=true")) |>
      httr2::req_method("DELETE") |> httr2::req_perform()
  }, error = function(e) NULL), add = TRUE)
  expect_equal(fld$name, "deep")

  # idempotent: re-running creates nothing new and doesn't error
  fld2 <- viya_create_folder(h, paste0(path, "/nested/deep"))
  expect_equal(fld2$id, fld$id)
})

test_that("viya_fs_mkdir/upload/download/list round-trip on the OS filesystem", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  base <- paste0("viyar_live_test_", as.integer(Sys.time()))
  viya_fs_mkdir(h, paste0(base, "/a/b"))

  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar fs live test", tmp_up)
  viya_fs_upload(h, tmp_up, paste0(base, "/a/hello.txt"))

  tmp_down <- tempfile(fileext = ".txt")
  viya_fs_download(h, paste0(base, "/a/hello.txt"), tmp_down)
  expect_equal(readLines(tmp_down), "viyar fs live test")

  listing <- viya_fs_list(h, paste0(base, "/a"))
  expect_true("hello.txt" %in% listing$name)
  expect_true("b" %in% listing$name)
  # the compute session's own scratch directory is cleaned up by Viya
  # when the session ends -- no explicit cleanup needed here.
})
