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
# `etag = NULL` makes GET /items/<id> send no ETag header.
.cw_mock <- function(seen, items = .cw_items, content = charToRaw("v1\n"),
                     etag = "\"etag-1\"") {
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
      return(httr2::response_json(
        headers = if (is.null(etag)) list() else list(ETag = etag),
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

test_that("viya_clinical_create() won't create a tenant, nor list it as a choice", {
  # The root is the only tenant and can't be created under it.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  err <- expect_error(
    viya_clinical_create("/Acme/x", "tenant", token = "t", url = .cw_url),
    "unknown type_id 'tenant'")
  expect_false(grepl("tenant,|, tenant|: tenant", conditionMessage(err)))
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

# ---- viya_clinical_delete() ------------------------------------------

test_that("viya_clinical_delete() sends a plain DELETE (recycle bin) by default", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  out <- viya_clinical_delete("/Acme/data/adsl.sas", token = "t",
                              url = .cw_url)

  expect_true("DELETE /clinicalRepository/repository/items/file-1" %in%
                seen$calls)
  expect_equal(out$id, "file-1")
})

test_that("viya_clinical_delete(permanent = TRUE) adds ?permanent=true", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_delete("/Acme/data", permanent = TRUE, token = "t",
                       url = .cw_url)

  expect_true(
    "DELETE /clinicalRepository/repository/items/fld-1?permanent=true" %in%
      seen$calls)
})

test_that("viya_clinical_delete() explains that a context needs permanent = TRUE", {
  # Found live: a context can't go to the recycle bin ("Context types
  # cannot be logically deleted"), so fail before sending anything.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  expect_error(viya_clinical_delete("/Acme", token = "t", url = .cw_url),
               "permanent = TRUE.*Permanently Delete Items")
  expect_false(any(grepl("^DELETE", seen$calls)))
})

test_that("viya_clinical_delete() refuses the repository root", {
  expect_error(viya_clinical_delete("/", token = "t", url = .cw_url),
               "root")
})

# ---- viya_clinical_update() ------------------------------------------

test_that("viya_clinical_update() PATCHes a flat body with the item's ETag", {
  # Found live: the body is flat ({"name": ...}), and leaving out If-Match
  # gets 428.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_update("/Acme/data/adsl.sas", name = "adsl_v2.sas",
                       token = "t", url = .cw_url)

  get_i   <- grep("^GET /clinicalRepository/repository/items/file-1$", seen$calls)
  patch_i <- grep("^PATCH /clinicalRepository/repository/items/file-1$", seen$calls)
  expect_length(patch_i, 1)
  expect_true(length(get_i) > 0 && min(get_i) < patch_i)
  req <- seen$reqs[[patch_i]]
  expect_equal(req$headers[["If-Match"]], "\"etag-1\"")
  expect_equal(req$body$data, list(name = "adsl_v2.sas"))
})

test_that("viya_clinical_update() can change only the description", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_update("/Acme/data", description = "ADaM programs",
                       token = "t", url = .cw_url)

  req <- .cw_find(seen, "^PATCH .*/items/fld-1$")
  expect_equal(req$body$data, list(description = "ADaM programs"))
})

test_that("viya_clinical_update() needs something to change", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  expect_error(viya_clinical_update("/Acme/data", token = "t", url = .cw_url),
               "name.*description")
  expect_null(seen$calls)
})

test_that("viya_clinical_update() rejects a name containing '/'", {
  # A rename can't move an item; a '/' in `name` would suggest it can.
  expect_error(viya_clinical_update("/Acme/data", name = "x/y", token = "t",
                                    url = .cw_url),
               "without '/'")
})

test_that("viya_clinical_update() needs an ETag from the server", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen, etag = NULL))

  expect_error(
    viya_clinical_update("/Acme/data/adsl.sas", name = "x.sas", token = "t",
                         url = .cw_url),
    "sent no ETag.*can't be updated safely")
  expect_false(any(grepl("^PATCH", seen$calls)))
})

# ---- check out / check in / undo -------------------------------------

.cw_ws <- "/clinicalRepository/workspaces/@currentUser"

# .cw_items with adsl.sas already checked out, for the check-in tests.
.cw_items_checked_out <- local({
  x <- .cw_items
  x[["/Acme/data/adsl.sas"]]$checkedOut <- TRUE
  x
})

test_that("viya_clinical_checkout() sends CHECK_OUT for the file's path", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))

  viya_clinical_checkout("/Acme/data/adsl.sas", token = "t", url = .cw_url)

  expect_true(paste0("POST ", .cw_ws,
                     "/files?path=%2FAcme%2Fdata%2Fadsl.sas&action=CHECK_OUT")
              %in% seen$calls)
  expect_false(any(grepl("/content$", seen$calls)))
})

test_that("viya_clinical_checkout() downloads the file when given local_path", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  dest <- withr::local_tempfile(fileext = ".sas")

  viya_clinical_checkout("/Acme/data/adsl.sas", dest, token = "t",
                         url = .cw_url)

  expect_true("POST /clinicalRepository/repository/items/file-1/content" %in%
                seen$calls)
  expect_equal(readLines(dest), "v1")
})

test_that("viya_clinical_checkout() won't overwrite a local file unless asked", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  dest <- withr::local_tempfile(fileext = ".sas")
  writeLines("my local edits", dest)

  expect_error(viya_clinical_checkout("/Acme/data/adsl.sas", dest,
                                      token = "t", url = .cw_url),
               "already exists.*overwrite = TRUE")
  expect_null(seen$calls)
  expect_equal(readLines(dest), "my local edits")

  viya_clinical_checkout("/Acme/data/adsl.sas", dest, overwrite = TRUE,
                         token = "t", url = .cw_url)
  expect_equal(readLines(dest), "v1")
})

test_that("viya_clinical_checkin() uploads to the workspace, then checks in", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen, items = .cw_items_checked_out))
  src <- withr::local_tempfile(fileext = ".txt")
  writeLines("v2", src)

  viya_clinical_checkin("/Acme/data/adsl.sas", src, comment = "fix TRTSDT",
                        token = "t", url = .cw_url)

  put_i <- grep(paste0("^PUT ", .cw_ws,
                       "/items\\?path=%2FAcme%2Fdata%2Fadsl.sas$"), seen$calls)
  ci_i  <- grep("action=CHECK_IN&comment=fix%20TRTSDT$", seen$calls)
  expect_length(put_i, 1)
  expect_length(ci_i, 1)
  expect_lt(put_i, ci_i)
  put <- seen$reqs[[put_i]]
  expect_equal(put$body$data$file$path, normalizePath(src))
  # The workspace copy takes the repository file's name, not the local one.
  expect_equal(put$body$data$file$name, "adsl.sas")
})

test_that("viya_clinical_checkin() leaves comment out of the query when NULL", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen, items = .cw_items_checked_out))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("v2", src)

  viya_clinical_checkin("/Acme/data/adsl.sas", src, token = "t", url = .cw_url)

  ci <- grep("action=CHECK_IN", seen$calls, value = TRUE)
  expect_length(ci, 1)
  expect_false(grepl("comment=", ci))
})

test_that("viya_clinical_checkin() refuses a file that isn't checked out", {
  # Checking first keeps the workspace untouched and gives a clearer error
  # than the server's "not currently checked out, is not a file or does not
  # exist".
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("v2", src)

  expect_error(viya_clinical_checkin("/Acme/data/adsl.sas", src, token = "t",
                                     url = .cw_url),
               "not checked out.*viya_clinical_checkout")
  expect_false(any(grepl("^PUT|CHECK_IN", seen$calls)))
})

test_that("viya_clinical_checkin() checks the local file before any request", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen, items = .cw_items_checked_out))

  expect_error(viya_clinical_checkin("/Acme/data/adsl.sas", "no-such.sas",
                                     token = "t", url = .cw_url),
               "does not exist")
  expect_null(seen$calls)
})

test_that("viya_clinical_undo_checkout() sends UNDO_CHECKOUT", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen, items = .cw_items_checked_out))

  viya_clinical_undo_checkout("/Acme/data/adsl.sas", token = "t",
                              url = .cw_url)

  expect_true(paste0("POST ", .cw_ws,
                     "/files?path=%2FAcme%2Fdata%2Fadsl.sas&action=UNDO_CHECKOUT")
              %in% seen$calls)
})

# ---- path and argument validation ------------------------------------

test_that("update/checkout/checkin/undo reject the root before any request", {
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("x", src)

  expect_error(viya_clinical_update("/", name = "x", token = "t",
                                    url = .cw_url), "root")
  expect_null(seen$calls)
  expect_error(viya_clinical_checkout("/", token = "t", url = .cw_url),
               "root")
  expect_null(seen$calls)
  expect_error(viya_clinical_checkin("/", src, token = "t", url = .cw_url),
               "root")
  expect_null(seen$calls)
  expect_error(viya_clinical_undo_checkout("/", token = "t", url = .cw_url),
               "root")
  expect_null(seen$calls)
})

test_that("viya_clinical_checkout() checks the local folder before CHECK_OUT", {
  # Otherwise the file is checked out and then the download fails.
  seen <- new.env()
  httr2::local_mocked_responses(.cw_mock(seen))
  dest <- file.path(withr::local_tempdir(), "no-such-dir", "adsl.sas")

  expect_error(viya_clinical_checkout("/Acme/data/adsl.sas", dest,
                                      token = "t", url = .cw_url),
               "the folder for .* does not exist")
  expect_null(seen$calls)
})
