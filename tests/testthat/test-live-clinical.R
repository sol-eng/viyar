test_that("viya_clinical_item() resolves the repository root", {
  skip_if_no_clinical()

  it <- viya_clinical_item("/")

  expect_equal(it$path, "/")
  expect_equal(it$primaryType, "CONTEXT")
  expect_equal(it$typeId, "tenant")
  expect_true(nzchar(it$id))
})

test_that("viya_clinical_item() surfaces the service's own message for a bad path", {
  skip_if_no_clinical()

  expect_error(viya_clinical_item("/no-such-path-viyar-live-test"),
               "No resource with the path")
})

test_that("viya_clinical_list() returns the documented columns", {
  # A freshly installed repository is empty at the root -- that is the
  # state of the `caf` cluster this was validated against -- so this
  # pins the zero-row shape as much as the populated one.
  skip_if_no_clinical()

  df <- viya_clinical_list("/")

  expect_s3_class(df, "data.frame")
  expect_equal(names(df),
               c("name", "id", "type", "type_id", "path", "size", "state",
                 "modified"))
  if (nrow(df)) expect_true(all(df$type %in% c("CONTEXT", "FOLDER", "FILE")))
})

test_that("viya_clinical_types() lists the deployment's type catalogue", {
  skip_if_no_clinical()

  df <- viya_clinical_types()

  expect_true(nrow(df) > 10)
  expect_true(all(c("study", "organization", "folder", "sasprogram") %in% df$id))
  expect_true(df$is_context[df$id == "study"])
  expect_false(df$is_context[df$id == "sasprogram"])
  expect_true(df$is_file[df$id == "sasprogram"])
  expect_false(df$is_file[df$id == "folder"])
})

test_that("viya_clinical_download() writes a ZIP archive", {
  # Content download is a POST that always answers with a zip, even for a
  # context: downloading the root gives back a zip of the whole subtree
  # (an empty one on a fresh repository, which still has the PK magic).
  skip_if_no_clinical()

  tmp <- withr::local_tempfile(fileext = ".zip")
  expect_message(viya_clinical_download("/", tmp), "zip archive")

  expect_true(file.exists(tmp))
  expect_equal(readBin(tmp, "raw", 2), charToRaw("PK"))
})

test_that("the paginated collection walk follows next links across pages", {
  # The repository root is empty on the validation cluster, so the walk
  # itself is exercised against /clinicalRepository/users, which does
  # emit next/prev links once you ask for a page smaller than the
  # collection. limit=1 forces at least one extra page per user.
  skip_if_no_clinical()

  h <- list(token = viya_token(), base = viya_config()$url)
  one_at_a_time <- .viya_clinical_collect(h, "/clinicalRepository/users?limit=1")
  all_at_once   <- .viya_clinical_collect(h, "/clinicalRepository/users?limit=100")

  expect_equal(length(one_at_a_time), length(all_at_once))
  expect_true(length(all_at_once) > 0)
  expect_equal(vapply(one_at_a_time, function(x) x$id, ""),
               vapply(all_at_once, function(x) x$id, ""))
})
