test_that("viya_create_folder creates missing intermediate folders one level at a time", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  # /Public exists; /Public/Reports and /Public/Reports/2026 don't yet.
  resp_public_ok <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_reports_404 <- httr2::response(status = 404)
  resp_reports_created <- httr2::response_json(status = 201, body = list(id = "reports-id", name = "Reports"))
  resp_2026_404 <- httr2::response(status = 404)
  resp_2026_created <- httr2::response_json(status = 201, body = list(id = "2026-id", name = "2026"))

  seq <- list(resp_public_ok, resp_reports_404, resp_reports_created,
              resp_2026_404, resp_2026_created)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_create_folder(h, "/Public/Reports/2026")
  expect_equal(out$id, "2026-id")
  expect_equal(i, 5)
})

test_that("viya_create_folder is idempotent when every segment already exists", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_public_ok <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_reports_ok <- httr2::response_json(status = 200, body = list(id = "reports-id", name = "Reports"))

  seq <- list(resp_public_ok, resp_reports_ok)
  i <- 0
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    seq[[i]]
  })

  out <- viya_create_folder(h, "/Public/Reports")
  expect_equal(out$id, "reports-id")
  expect_equal(i, 2)  # only the two existence checks -- no create calls
})

test_that("viya_create_folder validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_create_folder(bad_h, "/Public/x"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_create_folder(h, ""))
})

test_that("viya_delete_file resolves the file by name then DELETEs its uri", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_folder <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_members <- httr2::response_json(status = 200, body = list(items = list(
    list(name = "report.html", uri = "/files/files/report-id"))))
  resp_delete <- httr2::response(status = 204)

  seq <- list(resp_folder, resp_members, resp_delete)
  i <- 0
  seen <- NULL
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    if (i == 3) seen <<- req
    seq[[i]]
  })

  out <- viya_delete_file(h, "/Public/report.html")
  expect_null(out)
  expect_equal(i, 3)
  expect_match(seen$url, "/files/files/report-id$")
  expect_equal(seen$method, "DELETE")
})

test_that("viya_delete_file errors when the file isn't found in the folder", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_folder <- httr2::response_json(status = 200, body = list(id = "public-id", name = "Public"))
  resp_members <- httr2::response_json(status = 200, body = list(items = list()))

  seq <- list(resp_folder, resp_members)
  i <- 0
  httr2::local_mocked_responses(function(req) { i <<- i + 1; seq[[i]] })

  expect_error(viya_delete_file(h, "/Public/missing.html"), "not found")
})

test_that("viya_delete_file validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_delete_file(bad_h, "/Public/x.html"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_delete_file(h, ""))
})

test_that("viya_delete_folder resolves the folder then DELETEs it with recursive=true", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  resp_folder <- httr2::response_json(status = 200, body = list(id = "reports-id", name = "Reports"))
  resp_members <- httr2::response_json(status = 200, body = list(items = list()))
  resp_delete <- httr2::response(status = 204)

  seq <- list(resp_folder, resp_members, resp_delete)
  i <- 0
  seen <- NULL
  httr2::local_mocked_responses(function(req) {
    i <<- i + 1
    if (i == 3) seen <<- req
    seq[[i]]
  })

  out <- viya_delete_folder(h, "/Public/Reports")
  expect_null(out)
  expect_equal(i, 3)
  expect_match(seen$url, "/folders/folders/reports-id\\?recursive=true$")
  expect_equal(seen$method, "DELETE")
})

# Found live: recursive=true removes child folders but not child files --
# a folder holding a file still answers 409 "not empty". So every file in
# the tree is deleted through its own Files service URI first.
test_that("viya_delete_folder deletes child files (at any depth) before the folder itself", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  members <- list(
    "top-id" = list(
      list(name = "a.txt", type = "child", contentType = "file",
           uri = "/files/files/file-a"),
      list(name = "shortcut", type = "reference", contentType = "file",
           uri = "/files/files/not-ours"),
      list(name = "nested", type = "child", contentType = "folder",
           uri = "/folders/folders/nested-id")),
    "nested-id" = list(
      list(name = "b.txt", type = "child", contentType = "file",
           uri = "/files/files/file-b")))

  calls <- character()
  httr2::local_mocked_responses(function(req) {
    calls <<- c(calls, paste(req$method %||% "GET", sub("^https://[^/]+", "", req$url)))
    path <- sub("^https://[^/]+", "", req$url)
    if (grepl("@item", path))
      return(httr2::response_json(body = list(id = "top-id")))
    id <- sub("^/folders/folders/([^/?]+)/members.*", "\\1", path)
    if (id %in% names(members))
      return(httr2::response_json(body = list(items = members[[id]])))
    httr2::response(status = 204)
  })

  viya_delete_folder(h, "/Public/Reports")

  deletes <- grep("^DELETE ", calls, value = TRUE)
  expect_equal(deletes, c("DELETE /files/files/file-a",
                          "DELETE /files/files/file-b",
                          "DELETE /folders/folders/top-id?recursive=true"))
})

test_that("viya_delete_folder validates its arguments", {
  bad_h <- list(token = "t", base = "https://viya.example.com")
  expect_error(viya_delete_folder(bad_h, "/Public/Reports"))
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")
  expect_error(viya_delete_folder(h, ""))
})

test_that("an '@'-prefixed folder_path (a well-known Viya delegate like @myFolder) resolves via its own URI, not @item?path=", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  seen <- NULL
  httr2::local_mocked_responses(function(req) {
    seen <<- req$url
    httr2::response_json(status = 200, body = list(id = "myfolder-id", type = "myFolder"))
  })

  out <- viyar:::.viya_folder(h, "@myFolder")

  expect_equal(out$id, "myfolder-id")
  expect_match(seen, "/folders/folders/@myFolder$")
  expect_false(grepl("@item", seen, fixed = TRUE))
})

test_that("a real path still resolves via @item?path= as before", {
  h <- structure(list(token = "t", session = "sess1", context = "ctx",
                      base = "https://viya.example.com"), class = "viyar")

  seen <- NULL
  httr2::local_mocked_responses(function(req) {
    seen <<- req$url
    httr2::response_json(status = 200, body = list(id = "public-id"))
  })

  viyar:::.viya_folder(h, "/Public")

  expect_match(seen, "@item\\?path=", fixed = FALSE)
})
