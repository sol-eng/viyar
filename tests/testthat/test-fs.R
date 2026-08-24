test_that(".viya_fs_escape joins path segments with ~fs~, stripping trailing/double slashes, preserving a leading slash as a ~fs~ prefix", {
  expect_equal(.viya_fs_escape("a/b/c"), "a~fs~b~fs~c")
  expect_equal(.viya_fs_escape("/a/b/"), "~fs~a~fs~b")
  expect_equal(.viya_fs_escape("a"), "a")
  expect_equal(.viya_fs_escape("."), ".")
})

test_that(".viya_fs_escape preserves a leading slash as a distinct ~fs~ prefix (absolute vs relative)", {
  expect_equal(.viya_fs_escape("/tmp"), "~fs~tmp")
  expect_equal(.viya_fs_escape("tmp"), "tmp")
  expect_equal(.viya_fs_escape("/"), "~fs~")
  expect_equal(.viya_fs_escape("/a/b/c"), "~fs~a~fs~b~fs~c")
})

test_that("viya_fs_mkdir creates an absolute path from root, not relative to cwd", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_tmp_ok  <- httr2::response_json(status = 200, body = list(isDirectory = TRUE, name = "tmp"))
  resp_a_404   <- httr2::response(status = 404)
  resp_a_made  <- httr2::response_json(status = 201, body = list(isDirectory = TRUE, name = "a"))

  seq <- list(resp_tmp_ok, resp_a_404, resp_a_made)
  i <- 0
  seen_urls <- character(0)
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seen_urls[i] <<- req$url
    seq[[i]]
  })

  out <- viya_fs_mkdir(h, "/tmp/a")
  expect_equal(out, "/tmp/a")
  expect_equal(i, 3)
  expect_match(seen_urls[1], "/files/~fs~tmp$")
  expect_match(seen_urls[2], "/files/~fs~tmp~fs~a$")
  expect_match(seen_urls[3], "/files/~fs~tmp$")  # create 'a' under root-anchored parent 'tmp'
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

test_that("viya_fs_mkdir requires an active compute session", {
  h_no_session <- structure(list(token = "t", context = "ctx",
                                 base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_fs_mkdir(h_no_session, "a/b"))
})

test_that("viya_fs_upload PUTs raw file content to the escaped remote path", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  tmp <- tempfile(fileext = ".txt")
  writeLines("upload test content", tmp)

  seen <- NULL
  resp <- httr2::response_json(status = 200, body = list(name = "hello.txt"))
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_fs_upload(h, tmp, "a/b/hello.txt")
  expect_equal(out, "a/b/hello.txt")
  expect_match(seen$url, "/files/a~fs~b~fs~hello.txt/content$")
  expect_equal(seen$method, "PUT")
})

test_that("viya_fs_upload validates its arguments", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_fs_upload(h, "/no/such/file.txt", "a/b.txt"))
})

test_that("viya_fs_download GETs raw content and writes it to local_path", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  seen <- NULL
  resp <- httr2::response(status = 200, body = charToRaw("download test content\n"))
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  local_path <- tempfile(fileext = ".txt")
  out <- viya_fs_download(h, "a/b/hello.txt", local_path)
  expect_equal(out, local_path)
  expect_equal(readLines(local_path), "download test content")
  expect_match(seen$url, "/files/a~fs~b~fs~hello.txt/content$")
})

test_that("viya_fs_delete GETs for the ETag, then DELETEs with a matching If-Match header", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_get <- httr2::response(status = 200, headers = list(ETag = '"abc123"'))
  resp_delete <- httr2::response(status = 204)

  seq <- list(resp_get, resp_delete)
  i <- 0
  seen <- list()
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seen[[i]] <<- req
    seq[[i]]
  })

  out <- viya_fs_delete(h, "a/b/hello.txt")
  expect_equal(out, "a/b/hello.txt")
  expect_equal(i, 2)
  expect_match(seen[[1]]$url, "/files/a~fs~b~fs~hello.txt$")
  expect_match(seen[[2]]$url, "/files/a~fs~b~fs~hello.txt$")
  expect_equal(seen[[2]]$method, "DELETE")
  expect_equal(seen[[2]]$headers[["If-Match"]], '"abc123"')
})

test_that("viya_fs_delete works identically for a directory path (no recursive flag needed)", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_get <- httr2::response(status = 200, headers = list(ETag = '"dir-etag"'))
  resp_delete <- httr2::response(status = 204)

  seq <- list(resp_get, resp_delete)
  i <- 0
  seen <- list()
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seen[[i]] <<- req
    seq[[i]]
  })

  out <- viya_fs_delete(h, "/tmp/some_dir")
  expect_equal(out, "/tmp/some_dir")
  expect_equal(seen[[2]]$headers[["If-Match"]], '"dir-etag"')
})

test_that("viya_fs_delete validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_fs_delete(bad_h, "a/b"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_fs_delete(h, ""))
})

test_that("viya_fs_delete requires an active compute session", {
  h_no_session <- structure(list(token = "t", context = "ctx",
                                 base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_fs_delete(h_no_session, "a/b"))
})

test_that("viya_fs_list returns a data frame of directory members", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  resp <- httr2::response_json(status = 200, body = list(items = list(
    list(name = "b", isDirectory = TRUE, size = 15,
         path = "/gel/homes/samiul/a"),
    list(name = "hello.txt", isDirectory = FALSE, size = 26,
         path = "/gel/homes/samiul/a"))))
  seen <- NULL
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_fs_list(h, "a")
  expect_equal(names(out), c("name", "isDirectory", "size", "path"))
  expect_equal(out$name, c("b", "hello.txt"))
  expect_equal(out$isDirectory, c(TRUE, FALSE))
  expect_match(seen$url, "/files/a/members\\?limit=500$")
})

test_that("viya_fs_list(h, \".\") lists the session's cwd without curl collapsing the ./ segment", {
  # Found live: httr2/curl normalize away a literal "/./ " in a URL by
  # default (RFC 3986 dot-segment removal), so ".../files/./members"
  # silently became ".../files/members" -- the server then read "members"
  # itself as the {path} parameter and 404'd. path_as_is = TRUE disables
  # that normalization so a literal "." reaches the server as intended.
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  resp <- httr2::response_json(status = 200, body = list(items = list()))
  seen <- NULL
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_fs_list(h, ".")
  expect_equal(nrow(out), 0)
  expect_match(seen$url, "/files/\\./members\\?limit=500$")
  expect_true(isTRUE(seen$options$path_as_is))
})
