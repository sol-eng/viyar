test_that("create, upload, list, download and delete round-trip", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()

  sub <- paste0(dir, "/programs")
  it <- viya_clinical_create(sub)
  expect_equal(it$primaryType, "FOLDER")
  expect_equal(it$path, sub)

  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("proc print data=sashelp.class; run;", src)
  f <- viya_clinical_upload(src, sub, name = "print.sas")
  expect_equal(f$path, paste0(sub, "/print.sas"))
  expect_equal(f$typeId, "sasprogram")

  df <- viya_clinical_list(sub)
  expect_equal(df$name, "print.sas")
  expect_equal(df$size, file.size(src))

  out <- withr::local_tempfile(fileext = ".sas")
  viya_clinical_download(f$path, out)
  expect_equal(readLines(out), readLines(src))

  viya_clinical_delete(f$path)
  expect_equal(nrow(viya_clinical_list(sub)), 0)
})

test_that("check out, edit, then check in with a comment", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* v1 */", src)
  f <- viya_clinical_upload(src, dir, name = "adsl.sas")

  local <- withr::local_tempfile(fileext = ".sas")
  withr::defer(try(viya_clinical_undo_checkout(f$path), silent = TRUE))
  it <- viya_clinical_checkout(f$path, local)
  expect_true(it$checkedOut)
  expect_true(nzchar(it$checkedOutBy))
  expect_equal(readLines(local), "/* v1 */")

  writeLines("/* v2 */", local)
  it <- viya_clinical_checkin(f$path, local, comment = "v2 from viyar live test")
  expect_false(isTRUE(it$checkedOut))
  expect_equal(it$fileComment, "v2 from viyar live test")

  back <- withr::local_tempfile(fileext = ".sas")
  viya_clinical_download(f$path, back)
  expect_equal(readLines(back), "/* v2 */")
})

test_that("undo check-out releases the file, and misuse gets a clear error", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* v1 */", src)
  f <- viya_clinical_upload(src, dir, name = "adae.sas")

  withr::defer(try(viya_clinical_undo_checkout(f$path), silent = TRUE))
  it <- viya_clinical_checkout(f$path)
  expect_true(it$checkedOut)
  expect_error(viya_clinical_checkout(f$path), "already checked out")

  it <- viya_clinical_undo_checkout(f$path)
  expect_false(isTRUE(it$checkedOut))
  expect_error(viya_clinical_undo_checkout(f$path), "not currently checked out")
  expect_error(viya_clinical_checkin(f$path, src), "not checked out")
})

test_that("update renames a file and edits its description", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* a */", src)
  f <- viya_clinical_upload(src, dir, name = "a.sas")

  it <- viya_clinical_update(f$path, name = "b.sas",
                             description = "renamed by viyar")

  expect_equal(it$name, "b.sas")
  expect_equal(it$path, paste0(dir, "/b.sas"))
  expect_equal(it$description, "renamed by viyar")
  expect_error(viya_clinical_item(f$path), "No resource with the path")
})

test_that("a context can't be deleted without permanent = TRUE", {
  skip_if_no_clinical()
  local_clinical_folder()  # makes sure the test organization exists

  expect_error(viya_clinical_delete(.viya_live_clinical_org),
               "permanent = TRUE")
  expect_no_error(viya_clinical_item(.viya_live_clinical_org))
})
