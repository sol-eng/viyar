.cw_url <- "https://viya.example.com"

.cw_types <- list(
  list(id = "tenant", name = "Tenant", contextType = TRUE, fileType = FALSE),
  list(id = "organization", name = "Organization", contextType = TRUE,
       fileType = FALSE),
  list(id = "study", name = "Study", contextType = TRUE, fileType = FALSE),
  list(id = "folder", name = "Folder", contextType = FALSE, fileType = FALSE),
  list(id = "sasprogram", name = "SAS Program", contextType = FALSE,
       fileType = TRUE))

.cw_items <- list(
  "/" = list(id = "1", path = "/", typeId = "tenant",
             primaryType = "CONTEXT"),
  "/Acme" = list(id = "org-1", path = "/Acme", typeId = "organization",
                 primaryType = "CONTEXT"),
  "/Acme/data" = list(id = "fld-1", path = "/Acme/data", typeId = "folder",
                      primaryType = "FOLDER"),
  "/Acme/data/adsl.sas" = list(id = "file-1", path = "/Acme/data/adsl.sas",
                               typeId = "sasprogram", primaryType = "FILE",
                               checkedOut = FALSE))

# Records every request in `seen` and answers by URL, so a test can assert
# on what was sent without pinning the order of unrelated calls.
# `seen$calls` holds "METHOD /path?query" strings; `seen$reqs` the requests.
.cw_mock <- function(seen, items = .cw_items, content = charToRaw("v1\n")) {
  function(req) {
    method <- req$method %||% "GET"
    u <- sub("^https://[^/]+", "", req$url)
    seen$calls <- c(seen$calls, paste(method, u))
    seen$reqs  <- c(seen$reqs, list(req))
    if (startsWith(u, "/clinicalRepository/repository/paths?path=")) {
      p  <- utils::URLdecode(sub("^[^=]*=", "", u))
      it <- items[[p]]
      if (is.null(it))
        return(httr2::response_json(status = 404, body = list(
          message = paste0("No resource with the path \"", p,
                           "\" was found."))))
      return(httr2::response_json(body = it))
    }
    if (startsWith(u, "/clinicalRepository/types"))
      return(httr2::response_json(body = list(items = .cw_types,
                                              links = list())))
    if (method == "DELETE")
      return(httr2::response(status = 204))
    if (method == "GET" &&
        grepl("^/clinicalRepository/repository/items/[^/?]+$", u))
      return(httr2::response_json(headers = list(ETag = "\"etag-1\""),
                                  body = list(id = basename(u))))
    if (method == "POST" && grepl("/content$", u))
      return(httr2::response(
        headers = list(`Content-Type` = "application/x-sas"), body = content))
    if (method == "POST" && grepl("action=UNDO_CHECKOUT", u, fixed = TRUE))
      return(httr2::response(status = 200))
    httr2::response_json(body = list(id = "new-id", path = "/new",
                                     name = "new"))
  }
}

# The first recorded request whose "METHOD /path?query" matches `pattern`.
.cw_find <- function(seen, pattern) {
  i <- grep(pattern, seen$calls)
  if (!length(i))
    stop("no request matching ", pattern, "; calls were:\n",
         paste(seen$calls, collapse = "\n"))
  seen$reqs[[i[1]]]
}

# ---- viya_clinical_create() ------------------------------------------

test_that("viya_clinical_create() makes a folder with name/type in the query", {
  # Found live: the create endpoint reads `type`, `typeId` and `name` from
  # the query string and ignores a JSON body entirely.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_create("/Acme/new folder", token = "t", url = .cw_url)

  req <- .cw_find(seen, "^POST /clinicalRepository/repository/items/org-1/children")
  expect_match(req$url,
               "children?type=FOLDER&typeId=folder&name=new%20folder",
               fixed = TRUE)
  expect_null(req$body)
  expect_null(req$headers[["X-SAS-Clinical-Authorization"]])
})

test_that("viya_clinical_create() sends the admin header only under the root", {
  # Found live: creating under the root (a tenant) needs the header;
  # anywhere else, sending it gets 403 "Access is denied".
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_create("/Globex", "organization", token = "t", url = .cw_url)

  req <- .cw_find(seen, "^POST /clinicalRepository/repository/items/1/children")
  expect_match(req$url, "type=CONTEXT&typeId=organization&name=Globex",
               fixed = TRUE)
  expect_equal(req$headers[["X-SAS-Clinical-Authorization"]], "ADMIN")
})

test_that("viya_clinical_create() rejects an unknown type_id before writing", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  expect_error(
    viya_clinical_create("/Acme/x", "studdy", token = "t", url = .cw_url),
    "unknown type_id 'studdy'.*organization, study, folder")
  expect_false(any(grepl("^POST", seen$calls)))
})

test_that("viya_clinical_create() points file types at viya_clinical_upload()", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  expect_error(
    viya_clinical_create("/Acme/x.sas", "sasprogram", token = "t",
                         url = .cw_url),
    "viya_clinical_upload")
  expect_false(any(grepl("^POST", seen$calls)))
})

test_that("viya_clinical_create() rejects the root and relative paths", {
  expect_error(viya_clinical_create("/", token = "t", url = .cw_url),
               "root")
  expect_error(viya_clinical_create("Acme/x", token = "t", url = .cw_url),
               "absolute")
})

# ---- viya_clinical_upload() ------------------------------------------

test_that("viya_clinical_upload() PUTs one multipart file part to the container", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("proc print; run;", src)

  viya_clinical_upload(src, "/Acme/data", token = "t", url = .cw_url)

  req <- .cw_find(seen, "^PUT /clinicalRepository/repository/items/fld-1/content$")
  expect_equal(req$body$type, "multipart")
  expect_equal(names(req$body$data), "file")
  expect_equal(req$body$data$file$path, normalizePath(src))
  expect_equal(req$body$data$file$name, basename(src))
})

test_that("viya_clinical_upload() stores the file under `name`, on the file part", {
  # Found live: the stored name is the file part's own filename; a separate
  # `filename` form field is ignored.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("proc print; run;", src)

  viya_clinical_upload(src, "/Acme/data", name = "adsl.sas", token = "t",
                       url = .cw_url)

  req <- .cw_find(seen, "^PUT .*/items/fld-1/content$")
  expect_equal(req$body$data$file$name, "adsl.sas")
})

test_that("viya_clinical_upload() checks the local file before any request", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  expect_error(viya_clinical_upload("no-such-file.sas", "/Acme/data",
                                    token = "t", url = .cw_url),
               "does not exist")
  expect_null(seen$calls)
})

test_that("viya_clinical_upload() refuses to upload into a file", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("x", src)

  expect_error(viya_clinical_upload(src, "/Acme/data/adsl.sas", token = "t",
                                    url = .cw_url),
               "is a file")
  expect_false(any(grepl("^PUT", seen$calls)))
})
