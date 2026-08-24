test_that(".viya_fs_escape joins path segments with ~fs~, stripping leading/trailing/double slashes", {
  expect_equal(.viya_fs_escape("a/b/c"), "a~fs~b~fs~c")
  expect_equal(.viya_fs_escape("/a/b/"), "a~fs~b")
  expect_equal(.viya_fs_escape("a"), "a")
  expect_equal(.viya_fs_escape("."), ".")
})

test_that("viya_fs_mkdir creates missing intermediate directories one level at a time", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  # 'a' exists; 'a/b' and 'a/b/c' don't yet.
  resp_a_ok    <- httr2::response_json(status = 200, body = list(isDirectory = TRUE, name = "a"))
  resp_b_404   <- httr2::response(status = 404)
  resp_b_made  <- httr2::response_json(status = 201, body = list(isDirectory = TRUE, name = "b"))
  resp_c_404   <- httr2::response(status = 404)
  resp_c_made  <- httr2::response_json(status = 201, body = list(isDirectory = TRUE, name = "c"))

  seq <- list(resp_a_ok, resp_b_404, resp_b_made, resp_c_404, resp_c_made)
  i <- 0
  seen_urls <- character(0)
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seen_urls[i] <<- req$url
    seq[[i]]
  })

  out <- viya_fs_mkdir(h, "a/b/c")
  expect_equal(out, "a/b/c")
  expect_equal(i, 5)
  # existence checks hit the exact partial path; creates POST to the parent
  expect_match(seen_urls[1], "/files/a$")
  expect_match(seen_urls[2], "/files/a~fs~b$")
  expect_match(seen_urls[3], "/files/a$")       # create 'b' under parent 'a'
  expect_match(seen_urls[4], "/files/a~fs~b~fs~c$")
  expect_match(seen_urls[5], "/files/a~fs~b$")  # create 'c' under parent 'a/b'
})

test_that("viya_fs_mkdir is idempotent when every segment already exists", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_a_ok <- httr2::response_json(status = 200, body = list(isDirectory = TRUE, name = "a"))
  resp_b_ok <- httr2::response_json(status = 200, body = list(isDirectory = TRUE, name = "b"))

  seq <- list(resp_a_ok, resp_b_ok)
  i <- 0
  httr2::local_mocked_responses(function(req) { i <<- i + 1; seq[[i]] })

  out <- viya_fs_mkdir(h, "a/b")
  expect_equal(out, "a/b")
  expect_equal(i, 2)  # only existence checks -- no create calls
})

test_that("viya_fs_mkdir validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_fs_mkdir(bad_h, "a/b"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_fs_mkdir(h, ""))
})
