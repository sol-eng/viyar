test_that("a real compute session starts and ends cleanly", {
  skip_if_no_viya()
  h <- viya_session()
  expect_s3_class(h, "viyar")
  expect_true(nzchar(h$session))

  libs <- viya_librefs(h)
  expect_true(is.character(libs))

  ended <- viya_end(h)
  expect_true(isTRUE(ended))
})

test_that("viya_contexts and viya_sessions return well-formed data frames", {
  skip_if_no_viya()
  ctxs <- viya_contexts()
  expect_true(all(c("name", "id") %in% names(ctxs)))
  expect_true(nrow(ctxs) > 0)

  sess <- viya_sessions()
  expect_true(all(c("id", "state") %in% names(sess)))
})
