bad_h <- list(token = "t", base = "https://viya.example.com")  # missing class

test_that("token/url-based functions validate their arguments", {
  expect_error(viya_contexts(token = "", url = "https://x"), "token")
  expect_error(viya_contexts(token = "t", url = ""), "url")
  expect_error(viya_sessions(token = "", url = "https://x"))
  expect_error(viya_kill("sess-1", token = "", url = "https://x"))
  expect_error(viya_kill("", token = "t", url = "https://x"))
})

test_that("handle-based CAS functions validate their arguments", {
  expect_error(viya_caslib_files(bad_h, "Public"))
  expect_error(viya_caslib_tables(bad_h, "Public"))
  expect_error(viya_load_table(bad_h, "Public", "orders.sashdat"))
  expect_error(viya_unload_table(bad_h, "Public", "ORDERS"))
})

test_that("viya_members validates its handle", {
  expect_error(viya_members(bad_h, "WORK"))
})
