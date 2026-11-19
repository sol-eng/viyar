test_that("viya_clinical_versions() lists a versioned file's history", {
  path <- skip_if_no_versioned_file()

  df <- viya_clinical_versions(path)

  expect_equal(names(df), c("version", "file_version", "comment", "created_by",
                            "created", "size", "signed", "latest"))
  expect_true(nrow(df) >= 1)
  expect_equal(sum(df$latest), 1)
  expect_false(any(df$file_version == "-"))
  expect_s3_class(df$created, "POSIXct")
})

test_that("the latest version downloads identical to the current content", {
  path <- skip_if_no_versioned_file()
  v <- viya_clinical_versions(path)
  latest <- v$file_version[v$latest]
  cur <- withr::local_tempfile()
  old <- withr::local_tempfile()

  suppressMessages({
    viya_clinical_download(path, cur)
    viya_clinical_download_version(path, latest, old)
  })

  expect_identical(readBin(old, "raw", file.size(cur) + 1),
                   readBin(cur, "raw", file.size(cur) + 1))
})

test_that("the integer version is rejected before the request, with the labels", {
  path <- skip_if_no_versioned_file()
  v <- viya_clinical_versions(path)

  expect_error(
    viya_clinical_download_version(path, "99.9", withr::local_tempfile()),
    v$file_version[1], fixed = TRUE)
})

test_that("an unversioned file has one '-' version that still downloads", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* versions */", src)
  viya_clinical_upload(src, dir)
  f <- paste0(dir, "/", basename(src))

  v <- viya_clinical_versions(f)
  out <- withr::local_tempfile()
  suppressMessages(viya_clinical_download_version(f, "-", out))

  expect_equal(nrow(v), 1)
  expect_equal(v$file_version, "-")
  expect_equal(readLines(out), "/* versions */")
})

test_that("viya_clinical_download_many() zips the files a filter matches", {
  path <- skip_if_no_versioned_file()
  zip <- withr::local_tempfile(fileext = ".zip")

  suppressMessages(viya_clinical_download_many(
    paste0("eq(name,'", basename(path), "')"), zip))

  expect_true(basename(path) %in% utils::unzip(zip, list = TRUE)$Name)
})

test_that("viya_clinical_download_many() accepts a text search", {
  path <- skip_if_no_versioned_file()
  zip <- withr::local_tempfile(fileext = ".zip")

  # Found live: `text` is a full-text search, not a file-name match. "adsl"
  # returned adtte.sas7bdat and not adsl.xpt, so only assert that something
  # came back as a readable archive.
  suppressMessages(viya_clinical_download_many(
    local_path = zip, text = tools::file_path_sans_ext(basename(path))))

  expect_gt(nrow(utils::unzip(zip, list = TRUE)), 0)
})

test_that("viya_clinical_download_many() warns, writing nothing, on no match", {
  skip_if_no_clinical()
  zip <- withr::local_tempfile(fileext = ".zip")

  expect_warning(
    out <- viya_clinical_download_many("eq(name,'viyar-no-such-file-xyz')", zip),
    "nothing matched")
  expect_null(out)
  expect_false(file.exists(zip))
})
