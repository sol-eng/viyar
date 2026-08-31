test_that("viya_delete_file removes an uploaded file from SAS Content", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  fname <- paste0("viyar_live_test_del_", as.integer(Sys.time()), ".txt")
  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar delete live test", tmp_up)
  viya_upload(h, tmp_up, "/Public", name = fname)

  viya_delete_file(h, paste0("/Public/", fname))
  expect_error(viya_download(h, paste0("/Public/", fname), tempfile()),
               "not found")
})

test_that("viya_delete_folder removes a nested, non-empty SAS Content folder", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  path <- paste0("/Public/viyar_live_test_del_", as.integer(Sys.time()))
  viya_create_folder(h, paste0(path, "/nested/deeper"))

  tmp_up <- tempfile(fileext = ".txt")
  writeLines("in a folder about to be deleted", tmp_up)
  # a file at the top and one two levels down -- the Folders service's
  # own recursive DELETE refuses the whole tree over either of them.
  viya_upload(h, tmp_up, path, name = "leftover.txt")
  viya_upload(h, tmp_up, paste0(path, "/nested/deeper"), name = "deep.txt")

  viya_delete_folder(h, path)
  expect_error(.viya_folder(h, path))
})
