test_that("viya_test_folder() defaults to /Public and honours the env var and option", {
  withr::local_options(viyar.test_folder = NULL)
  withr::local_envvar(VIYAR_TEST_FOLDER = "")
  expect_equal(viya_test_folder(), "/Public")
  withr::local_envvar(VIYAR_TEST_FOLDER = "/Users/me/My Folder/")
  expect_equal(viya_test_folder(), "/Users/me/My Folder")
  withr::local_options(viyar.test_folder = "/opt/folder")
  expect_equal(viya_test_folder(), "/opt/folder")
})

test_that("skip_if_forbidden() skips on a 403 and passes other errors through", {
  httr2::local_mocked_responses(list(
    httr2::response_json(status = 403, body = list(message = "no")),
    httr2::response_json(status = 500, body = list(message = "boom"))))
  call <- function() httr2::request("https://x.example.com") |>
    httr2::req_perform()
  expect_snapshot_skip <- tryCatch(skip_if_forbidden(call()),
                                   skip = function(s) conditionMessage(s))
  expect_match(expect_snapshot_skip, "HTTP 403.*VIYAR_TEST_FOLDER")
  expect_error(skip_if_forbidden(call()), class = "httr2_http_500")
  expect_equal(skip_if_forbidden(42), 42)
})
