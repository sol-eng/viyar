.cv_url <- "https://viya.example.com"

.cv_version <- function(version, file_version, comment = NULL, latest = FALSE) {
  v <- list(version = version, fileId = "f1", path = "/Acme/adsl.xpt",
            fileVersion = file_version, createdBy = "samiul",
            creationTimeStamp = "2026-10-05T19:43:07.327Z", size = 114640,
            signed = FALSE, latest = latest)
  if (!is.null(comment)) v$comment <- comment
  v
}

.cv_page <- function(items, next_href = NULL) {
  links <- list(list(rel = "self", href = "/clinicalRepository/x"))
  if (!is.null(next_href))
    links <- c(links, list(list(rel = "next", href = next_href)))
  list(name = "versions", start = 0, count = length(items), limit = 100,
       items = items, links = links)
}

# Dispatches on the request URL, as test-clinical.R does. `versions` is a
# list of page bodies served in turn; `version_content` and `bulk` are the
# raw bodies for the two download endpoints.
.mock_versions <- function(seen, versions = NULL, version_content = NULL,
                           bulk = NULL, bulk_type = "application/zip") {
  item <- list(id = "f1", path = "/Acme/adsl.xpt", typeId = "file",
               primaryType = "FILE", state = "ACTIVE", size = 114640)
  function(req) {
    seen$url <- c(seen$url, req$url)
    seen$method <- c(seen$method, req$method %||% "GET")
    seen$body <- c(seen$body, list(req$body$data))
    u <- req$url
    if (grepl("/repository/paths", u))
      return(httr2::response_json(status = 200, body = item))
    if (grepl("/versions/[^/]+/content$", u))
      return(httr2::response(status = 200,
                             headers = list("Content-Type" = "application/octet-stream"),
                             body = version_content))
    if (grepl("/versions", u)) {
      i <- sum(grepl("/versions", seen$url) & !grepl("/content", seen$url))
      if (i > length(versions)) stop("unexpected extra versions request: ", u)
      return(httr2::response_json(status = 200, body = versions[[i]]))
    }
    if (grepl("/repository/files/content$", u))
      return(httr2::response(status = 200,
                             headers = list("Content-Type" = bulk_type),
                             body = bulk))
    stop("unexpected request: ", u)
  }
}

# ---- viya_clinical_versions() ----------------------------------------

test_that("viya_clinical_versions() returns one row per version", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(seen, versions = list(
    .cv_page(list(.cv_version(2, "2.0", comment = "fix", latest = TRUE),
                  .cv_version(1, "1.0"))))))

  df <- viya_clinical_versions("/Acme/adsl.xpt", token = "t", url = .cv_url)

  expect_equal(names(df), c("version", "file_version", "comment", "created_by",
                            "created", "size", "signed", "latest"))
  expect_equal(df$file_version, c("2.0", "1.0"))
  expect_equal(df$comment, c("fix", NA))
  expect_equal(df$latest, c(TRUE, FALSE))
  expect_s3_class(df$created, "POSIXct")
  expect_match(seen$url[2], "/repository/items/f1/versions", fixed = TRUE)
})

test_that("viya_clinical_versions() follows next links", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(seen, versions = list(
    .cv_page(list(.cv_version(2, "2.0", latest = TRUE)),
             next_href = "/clinicalRepository/repository/items/f1/versions?start=1"),
    .cv_page(list(.cv_version(1, "1.0"))))))

  df <- viya_clinical_versions("/Acme/adsl.xpt", token = "t", url = .cv_url)

  expect_equal(df$file_version, c("2.0", "1.0"))
})

# ---- viya_clinical_download_version() --------------------------------

test_that("viya_clinical_download_version() GETs the version's content by fileVersion", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(
    seen, versions = list(.cv_page(list(.cv_version(1, "1.0", latest = TRUE)))),
    version_content = charToRaw("v1 bytes")))
  tmp <- withr::local_tempfile()

  out <- suppressMessages(viya_clinical_download_version(
    "/Acme/adsl.xpt", "1.0", tmp, token = "t", url = .cv_url))

  expect_equal(out, tmp)
  expect_equal(readBin(tmp, "raw", 100), charToRaw("v1 bytes"))
  expect_match(tail(seen$url, 1), "/versions/1.0/content$")
  expect_equal(tail(seen$method, 1), "GET")
})

test_that("viya_clinical_download_version() names the available versions on a miss", {
  # The service wants the fileVersion string ("1.0"), not the integer
  # `version` column; passing 1 answers 404 (found live), so say what works.
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(
    seen, versions = list(.cv_page(list(.cv_version(1, "1.0", latest = TRUE))))))
  tmp <- withr::local_tempfile()

  expect_error(
    viya_clinical_download_version("/Acme/adsl.xpt", "7.0", tmp,
                                   token = "t", url = .cv_url),
    "1.0")
  expect_false(file.exists(tmp))
  expect_false(any(grepl("/content$", seen$url)))
})

test_that("viya_clinical_download_version() validates its arguments", {
  expect_error(viya_clinical_download_version("/x", 1, "f", token = "t",
                                              url = .cv_url))
  expect_error(viya_clinical_download_version("/x", "1.0", "", token = "t",
                                              url = .cv_url))
})

# ---- viya_clinical_download_many() -----------------------------------

test_that("viya_clinical_download_many() POSTs the filter as a JSON body", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(seen, bulk = charToRaw("PK-zip")))
  tmp <- withr::local_tempfile(fileext = ".zip")

  out <- suppressMessages(viya_clinical_download_many(
    "eq(name,'adsl.xpt')", tmp, token = "t", url = .cv_url))

  expect_equal(out, tmp)
  expect_equal(readBin(tmp, "raw", 100), charToRaw("PK-zip"))
  expect_equal(seen$method, "POST")
  expect_equal(seen$body[[1]], list(filter = "eq(name,'adsl.xpt')"))
})

test_that("viya_clinical_download_many() sends text search as `text`", {
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(seen, bulk = charToRaw("PK-zip")))
  tmp <- withr::local_tempfile(fileext = ".zip")

  suppressMessages(viya_clinical_download_many(
    local_path = tmp, text = "adsl", token = "t", url = .cv_url))

  expect_equal(seen$body[[1]], list(text = "adsl"))
})

test_that("viya_clinical_download_many() warns and writes nothing when nothing matches", {
  # A no-match answers 200 with an empty body, not an error (found live).
  seen <- new.env()
  httr2::local_mocked_responses(.mock_versions(seen, bulk = raw(0)))
  tmp <- withr::local_tempfile(fileext = ".zip")

  expect_warning(
    out <- viya_clinical_download_many("eq(name,'nope')", tmp, token = "t",
                                       url = .cv_url),
    "nothing matched")
  expect_null(out)
  expect_false(file.exists(tmp))
})

test_that("viya_clinical_download_many() needs a filter or text, and a destination", {
  expect_error(viya_clinical_download_many(local_path = "x.zip", token = "t",
                                           url = .cv_url), "filter")
  expect_error(viya_clinical_download_many("eq(name,'a')", "", token = "t",
                                           url = .cv_url))
})
