.clin_url <- "https://viya.example.com"

# Dispatches on the request URL rather than on call order, so a test can
# assert which endpoints were hit without also pinning the sequence they
# were hit in. Every URL is appended to `seen$url`.
.mock_clinical <- function(seen, item = NULL, pages = NULL, content = NULL,
                           types = NULL, content_type = "application/zip") {
  if (is.null(item))
    item <- list(id = "1", path = "/", typeId = "tenant",
                 primaryType = "CONTEXT", state = "ACTIVE", size = 0)
  function(req) {
    seen$url <- c(seen$url, req$url)
    seen$method <- c(seen$method, req$method %||% "GET")
    u <- req$url
    if (grepl("/repository/paths", u))
      return(httr2::response_json(status = 200, body = item))
    if (grepl("/content$", u))
      return(httr2::response(status = 200,
                             headers = list("Content-Type" = content_type),
                             body = content))
    if (grepl("/types", u))
      return(httr2::response_json(status = 200,
                                  body = list(items = types, links = list())))
    if (grepl("/children", u)) {
      # `pages` is a list of already-built collection bodies; each is served
      # in turn so a test can hand back a `next` link and check it is followed.
      i <- sum(grepl("/children", seen$url))
      if (i > length(pages)) stop("unexpected extra children request: ", u)
      return(httr2::response_json(status = 200, body = pages[[i]]))
    }
    stop("unexpected request: ", u)
  }
}

.clin_page <- function(items, next_href = NULL) {
  links <- list(list(rel = "self", href = "/clinicalRepository/x"))
  if (!is.null(next_href))
    links <- c(links, list(list(rel = "next", href = next_href)))
  list(name = "items", start = 0, count = length(items),
       limit = 100, items = items, links = links)
}

.clin_item <- function(name, id, type = "FOLDER", type_id = "folder",
                       path = paste0("/", name), size = 0) {
  list(version = 1, id = id, name = name, typeId = type_id,
       primaryType = type, path = path, size = size, state = "ACTIVE",
       modifiedTimeStamp = "2026-08-25T15:00:00.000Z")
}

# ---- viya_clinical_item() --------------------------------------------

test_that("viya_clinical_item() resolves an item by repository path", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(seen))

  it <- viya_clinical_item("/", token = "t", url = .clin_url)

  expect_equal(it$id, "1")
  expect_equal(it$path, "/")
  expect_equal(it$primaryType, "CONTEXT")
})

test_that("viya_clinical_item() URL-encodes the path it asks for", {
  # The Clinical Repository resolves items through a `path=` query
  # parameter, so every separator has to survive as %2F rather than being
  # read as part of the endpoint's own URL structure.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(seen))

  viya_clinical_item("/Acme/Study 1", token = "t", url = .clin_url)

  expect_true(any(grepl(
    "/clinicalRepository/repository/paths?path=%2FAcme%2FStudy%201",
    seen$url, fixed = TRUE)))
})

test_that("viya_clinical_item() rejects an empty path", {
  expect_error(viya_clinical_item("", token = "t", url = .clin_url))
})

test_that("viya_clinical_item() rejects a missing URL with the standard hint", {
  expect_error(viya_clinical_item("/", token = "t", url = ""),
               "No Viya URL configured")
})

# ---- viya_clinical_list() --------------------------------------------

test_that("viya_clinical_list() resolves the path, then lists that item's children", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    item  = list(id = "42", path = "/Acme", primaryType = "CONTEXT"),
    pages = list(.clin_page(list(
      .clin_item("Study 1", "43", "CONTEXT", "study", "/Acme/Study 1"),
      .clin_item("protocol.sas", "44", "FILE", "sasprogram",
                 "/Acme/protocol.sas", size = 812))))))

  df <- viya_clinical_list("/Acme", token = "t", url = .clin_url)

  expect_equal(names(df),
               c("name", "id", "type", "type_id", "path", "size", "state",
                 "modified"))
  expect_equal(df$name, c("Study 1", "protocol.sas"))
  expect_equal(df$type, c("CONTEXT", "FILE"))
  expect_equal(df$type_id, c("study", "sasprogram"))
  expect_equal(df$size, c(0, 812))
  expect_true(any(grepl("/repository/items/42/children", seen$url)))
})

test_that("viya_clinical_list() follows the collection's `next` link to the end", {
  # Every existing list function in this package takes one page at a
  # hardcoded limit and silently truncates -- a known gap recorded in
  # CLAUDE.md. The Clinical Repository does emit RFC-style next/prev
  # links (confirmed live against /clinicalRepository/users), so this
  # one paginates properly.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    pages = list(
      .clin_page(list(.clin_item("a", "2")),
                 next_href = "/clinicalRepository/repository/items/1/children?start=1&limit=1"),
      .clin_page(list(.clin_item("b", "3")),
                 next_href = "/clinicalRepository/repository/items/1/children?start=2&limit=1"),
      .clin_page(list(.clin_item("c", "4"))))))

  df <- viya_clinical_list("/", token = "t", url = .clin_url)

  expect_equal(df$name, c("a", "b", "c"))
  expect_true(any(grepl("start=1&limit=1", seen$url, fixed = TRUE)))
  expect_true(any(grepl("start=2&limit=1", seen$url, fixed = TRUE)))
})

test_that("viya_clinical_list() stops rather than looping on a self-referential `next`", {
  seen <- new.env()
  httr2::local_mocked_responses(function(req) {
    seen$url <- c(seen$url, req$url)
    if (grepl("/repository/paths", req$url))
      return(httr2::response_json(status = 200,
                                  body = list(id = "1", path = "/")))
    httr2::response_json(status = 200, body = .clin_page(
      list(.clin_item("a", "2")),
      next_href = "/clinicalRepository/repository/items/1/children?limit=100"))
  })

  expect_warning(df <- viya_clinical_list("/", token = "t", url = .clin_url),
                 "truncated")
  expect_true(nrow(df) > 0)
})

test_that("viya_clinical_list() returns a typed zero-row frame for an empty container", {
  # The `caf` repository really is empty at the root, so this is the
  # shape a first call against a fresh deployment actually produces --
  # it must still be a data.frame with the documented columns, not NULL.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen, pages = list(.clin_page(list()))))

  df <- viya_clinical_list("/", token = "t", url = .clin_url)

  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 0)
  expect_equal(names(df),
               c("name", "id", "type", "type_id", "path", "size", "state",
                 "modified"))
})

test_that("viya_clinical_list() reports a container's size as NA, not -1", {
  # Found live: contexts and folders carry `size = -1` -- "no size", not a
  # byte count -- while files carry their real size.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    pages = list(.clin_page(list(
      .clin_item("data", "2", size = -1),
      .clin_item("hello.sas", "3", "FILE", "sasprogram", size = 42))))))

  df <- viya_clinical_list("/", token = "t", url = .clin_url)

  expect_equal(df$size, c(NA, 42))
})

test_that("viya_clinical_list() tolerates an item with no name", {
  # The repository root itself carries no `name` attribute -- only a
  # `path` of "/" -- so any item field can legitimately be absent.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    pages = list(.clin_page(list(
      list(id = "9", path = "/", primaryType = "CONTEXT"))))))

  df <- viya_clinical_list("/", token = "t", url = .clin_url)

  expect_true(is.na(df$name))
  expect_equal(df$id, "9")
})

# ---- viya_clinical_download() ----------------------------------------

test_that("viya_clinical_download() POSTs to the item's content endpoint", {
  # Downloading is a POST, not a GET: the service answers GET on this
  # endpoint with 405 and names POST/PUT as the supported methods
  # (confirmed live).
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    item = list(id = "7", path = "/Acme/protocol.sas", primaryType = "FILE"),
    content = as.raw(c(0x50, 0x4b, 0x05, 0x06))))

  tmp <- withr::local_tempfile(fileext = ".zip")
  out <- viya_clinical_download("/Acme/protocol.sas", tmp,
                                token = "t", url = .clin_url)

  expect_equal(out, tmp)
  expect_equal(readBin(tmp, "raw", 4), as.raw(c(0x50, 0x4b, 0x05, 0x06)))
  hit <- grep("/repository/items/7/content$", seen$url)
  expect_length(hit, 1)
  expect_equal(seen$method[hit], "POST")
})

test_that("viya_clinical_download() writes a file's raw content, and says so", {
  # Found live: a FILE comes back as its own bytes with its own media type
  # (application/x-sas for a .sas program) -- only a container is zipped.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen,
    item = list(id = "7", path = "/Acme/protocol.sas", primaryType = "FILE"),
    content = charToRaw("proc print; run;\n"),
    content_type = "application/x-sas"))

  tmp <- withr::local_tempfile(fileext = ".sas")
  msg <- testthat::capture_messages(
    viya_clinical_download("/Acme/protocol.sas", tmp, token = "t", url = .clin_url))

  expect_equal(readLines(tmp), "proc print; run;")
  expect_false(any(grepl("zip", msg)))
})

test_that("viya_clinical_download() flags a container's download as a zip archive", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(
    seen, content = as.raw(c(0x50, 0x4b, 0x05, 0x06))))

  tmp <- withr::local_tempfile(fileext = ".zip")
  expect_message(viya_clinical_download("/", tmp, token = "t", url = .clin_url),
                 "zip archive")
})

test_that("viya_clinical_download() requires a local destination", {
  expect_error(viya_clinical_download("/x", "", token = "t", url = .clin_url))
})

# ---- viya_clinical_types() -------------------------------------------

test_that("viya_clinical_types() returns the type catalogue as a frame", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_clinical(seen, types = list(
    list(id = "study", name = "Study", contextType = TRUE, fileType = FALSE),
    list(id = "sasprogram", name = "SAS Program", contextType = FALSE,
         fileType = TRUE))))

  df <- viya_clinical_types(token = "t", url = .clin_url)

  expect_equal(names(df), c("id", "name", "is_context", "is_file"))
  expect_equal(df$id, c("study", "sasprogram"))
  expect_equal(df$is_context, c(TRUE, FALSE))
  expect_equal(df$is_file, c(FALSE, TRUE))
})

# ---- error surfacing -------------------------------------------------

test_that("a Clinical Repository error body reaches the caller's error message", {
  httr2::local_mocked_responses(function(req)
    httr2::response_json(
      status = 404,
      url = req$url,
      body = list(errorCode = 145016,
                  message = "No resource with the path \"/nope\" was found.",
                  remediation = "Either the path is incorrect or the desired resource does not exist.",
                  httpStatusCode = 404)))

  expect_error(viya_clinical_item("/nope", token = "t", url = .clin_url),
               "No resource with the path")
})
