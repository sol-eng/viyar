# Clinical Repository Write Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add write functions for the SAS Clinical Acceleration Repository to viyar: create containers, upload new files, check out / check in / undo check-out, rename/edit, and delete.

**Architecture:** One new file, `R/clinical-write.R`, alongside the read-only `R/clinical.R` from PR #7. Every function takes `token`/`url` (no compute session), resolves paths with the existing `viya_clinical_item()`, sends requests through the package's single request builder `.viya_req()`, and returns the item's metadata invisibly. Check-out and check-in go through the server's per-user workspace, but the workspace never appears in the public API.

**Tech Stack:** R, httr2 (>= 1.0.0) for HTTP, curl (`curl::form_file()`) for multipart uploads, testthat 3e with `httr2::local_mocked_responses()` for unit tests, withr for test cleanup, roxygen2 for docs and NAMESPACE.

**Spec:** `docs/superpowers/specs/2026-10-01-clinical-write-design.md`. Read its "Facts established live" and "Probe results" sections before starting; every request shape in this plan comes from them.

## Global Constraints

- Branch: `feat-clinical-write` (stacked on `feat-clinical-repository`, PR #7). Commit only to this branch. Do not push.
- No new dependencies. `httr2`, `curl`, `jsonlite`, `utils` are already in `Imports`; `withr` and `testthat` are in `Suggests`.
- Every request goes through `.viya_req(h, path)` (in `R/utils.R`). Never call `httr2::request()` directly.
- Function signature pattern, copied from `R/clinical.R`: data arguments first, then `token = viya_token(), url = viya_config()$url`. First line of every body: `h <- .viya_clinical_h(token, url)`.
- Every exported function returns item metadata **invisibly** and emits one `message()` describing what it did, matching `viya_clinical_download()`.
- **Lock/unlock is out of scope.** Probe 2 in the spec showed there is no API for it. Do not add it.
- **Version history is out of scope.** It is being built on a separate branch.
- Code comments explain *why*, briefly, and cite "found live" where a behaviour was confirmed on a real cluster. Match the comment density of `R/clinical.R`.
- After changing any roxygen block, run `Rscript -e 'roxygen2::roxygenise()'` and commit the regenerated `NAMESPACE` and `man/` files with the code.
- Unit test command (run from the repo root):
  `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
- Full unit suite (must stay at 0 failures):
  `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_dir("tests/testthat")'`
  Live tests skip themselves when `VIYA_URL`/`VIYA_TOKEN` are unset.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `R/clinical-write.R` | create | All write functions and their three private helpers. |
| `tests/testthat/test-clinical-write.R` | create | Mocked unit tests: exact method, URL, headers and body for each function. |
| `tests/testthat/helper-live.R` | modify | Add the long-lived test organization and the per-test folder helper. |
| `tests/testthat/test-live-clinical-write.R` | create | Live tests against a real cluster. |
| `README.md` | modify | Replace "this release is read-only" with a section on editing files. |
| `CLAUDE.md` | modify | Architecture entry for `R/clinical-write.R`; probe results; why lock was dropped. |
| `NAMESPACE`, `man/*.Rd` | regenerate | By roxygen. Never edit by hand. |

---

### Task 1: Helpers, test mock, and `viya_clinical_create()`

**Files:**
- Create: `R/clinical-write.R`
- Create: `tests/testthat/test-clinical-write.R`

**Interfaces:**
- Consumes (existing, in `R/clinical.R`): `.viya_clinical_h(token, url)` → `list(token, base)`; `viya_clinical_item(path, token, url)` → item list with `id`, `path`, `typeId`, `primaryType`, `checkedOut`; `viya_clinical_types(token, url)` → data frame `id`, `name`, `is_context`, `is_file`. From `R/utils.R`: `.viya_req(h, path)` → httr2 request.
- Produces (used by Tasks 2-5):
  - `.viya_clinical_item_uri(id)` → `"/clinicalRepository/repository/items/<id>"`
  - `.viya_clinical_enc(x)` → `utils::URLencode(x, reserved = TRUE)`
  - `.viya_clinical_split(path)` → `list(parent = <chr>, name = <chr>)`; errors on a relative path or the root
  - `viya_clinical_create(path, type_id = "folder", token, url)` → created item (list), invisibly
  - Test helpers in `test-clinical-write.R`: `.cw_url`, `.cw_types`, `.cw_items`, `.cw_mock(seen, items, content)`, `.cw_find(seen, pattern)`

- [ ] **Step 1: Write the test mock and the failing tests**

Create `tests/testthat/test-clinical-write.R`:

```r
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: 5 failures/errors with `could not find function "viya_clinical_create"`.

- [ ] **Step 3: Write the helpers and `viya_clinical_create()`**

Create `R/clinical-write.R`:

```r
# Writes to the SAS Clinical Acceleration Repository. The read side and the
# shared helpers (.viya_clinical_h(), .viya_clinical_collect()) live in
# R/clinical.R. Every request shape here was confirmed against a live
# cluster before it was written -- see the R/clinical-write.R entry in
# CLAUDE.md, and docs/superpowers/specs/2026-10-01-clinical-write-design.md.

.viya_clinical_item_uri <- function(id)
  paste0("/clinicalRepository/repository/items/", id)

.viya_clinical_enc <- function(x) utils::URLencode(x, reserved = TRUE)

# Splits an absolute repository path into its parent's path and its own
# name. Rejects the root, which has no parent and can't be written to.
.viya_clinical_split <- function(path) {
  if (!is.character(path) || length(path) != 1 || !startsWith(path, "/"))
    stop("`path` must be an absolute repository path, e.g. \"/Acme/Study 1\"")
  path <- sub("/+$", "", path)
  if (!nzchar(path)) stop("`path` can't be the repository root")
  list(parent = dirname(path), name = basename(path))
}

#' Create a Clinical Repository context or folder
#'
#' Creates one container at `path`. Its parent must already exist -- this
#' does not create missing parents.
#'
#' Creating directly under the repository root (a new organization, say)
#' needs Clinical Administrators membership. Anywhere else, your own
#' permissions on the parent apply.
#'
#' @param path Repository path of the container to create, e.g.
#'   `"/Acme/Study 1/programs"`.
#' @param type_id The kind of container: `"folder"` (the default), or a
#'   context type such as `"organization"` or `"study"`. See
#'   [viya_clinical_types()] for what your deployment offers. To add a
#'   file, use [viya_clinical_upload()] instead.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The new item's metadata (see [viya_clinical_item()]),
#'   invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_create("/Acme", "organization")
#' viya_clinical_create("/Acme/programs")
#' }
#' @export
viya_clinical_create <- function(path, type_id = "folder",
                                 token = viya_token(),
                                 url = viya_config()$url) {
  h  <- .viya_clinical_h(token, url)
  sp <- .viya_clinical_split(path)
  stopifnot(is.character(type_id), length(type_id) == 1)

  types <- viya_clinical_types(token, url)
  if (!type_id %in% types$id)
    stop("unknown type_id '", type_id, "'; container types on this ",
         "deployment: ", paste(types$id[!types$is_file], collapse = ", "))
  if (types$is_file[types$id == type_id])
    stop("'", type_id, "' is a file type; add files with ",
         "viya_clinical_upload()")
  kind <- if (types$is_context[types$id == type_id]) "CONTEXT" else "FOLDER"

  parent <- viya_clinical_item(sp$parent, token, url)
  # Found live: `type`, `typeId` and `name` must be query parameters; a JSON
  # body is ignored ("Required request parameter "name" is missing").
  req <- .viya_req(h, paste0(.viya_clinical_item_uri(parent$id),
                             "/children?type=", kind,
                             "&typeId=", .viya_clinical_enc(type_id),
                             "&name=", .viya_clinical_enc(sp$name))) |>
    httr2::req_method("POST")
  # Found live: creating under the root needs the admin header; sending it
  # anywhere else gets 403 "Access is denied".
  if (identical(parent$typeId, "tenant"))
    req <- httr2::req_headers(req, `X-SAS-Clinical-Authorization` = "ADMIN")
  it <- req |> httr2::req_perform() |> httr2::resp_body_json()
  message("created ", type_id, " ", path)
  invisible(it)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: `[ FAIL 0 | ... | PASS 12 ]` (or similar: zero failures, no skips).

- [ ] **Step 5: Regenerate docs and commit**

```bash
Rscript -e 'roxygen2::roxygenise()'
git add R/clinical-write.R tests/testthat/test-clinical-write.R NAMESPACE man/viya_clinical_create.Rd
git commit -m "Add viya_clinical_create() for Clinical Repository containers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `viya_clinical_upload()`

**Files:**
- Modify: `R/clinical-write.R` (append)
- Modify: `tests/testthat/test-clinical-write.R` (append)

**Interfaces:**
- Consumes: `.viya_clinical_item_uri()` (Task 1); `.cw_mock()`, `.cw_find()`, `.cw_url` (Task 1 test file).
- Produces: `viya_clinical_upload(local_path, path, name = basename(local_path), token, url)` → the new file's item list, invisibly. Task 6's live tests use it to seed files.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-clinical-write.R`:

```r
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
  expect_equal(req$body$data$file$path, src)
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: the 4 new tests fail with `could not find function "viya_clinical_upload"`; Task 1's tests still pass.

- [ ] **Step 3: Write `viya_clinical_upload()`**

Append to `R/clinical-write.R`:

```r
#' Upload a new file to the Clinical Repository
#'
#' Adds a local file to a context or folder. This is for files that don't
#' exist in the repository yet; to change an existing file, check it out
#' with [viya_clinical_checkout()] and back in with
#' [viya_clinical_checkin()].
#'
#' A deployment can refuse some file extensions. The server's own message
#' says so (for example, "Files with extension "R" cannot be uploaded").
#'
#' @param local_path Path of the local file to upload.
#' @param path Repository path of the context or folder to upload into.
#' @param name Name to store the file under; defaults to `local_path`'s
#'   own file name.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The new file's metadata (see [viya_clinical_item()]),
#'   invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_upload("adsl.sas", "/Acme/Study 1/programs")
#' }
#' @export
viya_clinical_upload <- function(local_path, path, name = basename(local_path),
                                 token = viya_token(),
                                 url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(is.character(local_path), length(local_path) == 1,
            nzchar(path), nzchar(name))
  if (!file.exists(local_path)) stop("'", local_path, "' does not exist")

  parent <- viya_clinical_item(path, token, url)
  if (identical(parent$primaryType, "FILE"))
    stop("'", path, "' is a file; give the context or folder to upload into")
  # Found live: the stored name is the file part's own filename -- a
  # separate `filename` form field is ignored.
  it <- .viya_req(h, paste0(.viya_clinical_item_uri(parent$id), "/content")) |>
    httr2::req_method("PUT") |>
    httr2::req_body_multipart(file = curl::form_file(local_path, name = name)) |>
    httr2::req_perform() |> httr2::resp_body_json()
  message("uploaded ", local_path, " -> ", it$path %||% path)
  invisible(it)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: `FAIL 0`.

- [ ] **Step 5: Regenerate docs and commit**

```bash
Rscript -e 'roxygen2::roxygenise()'
git add R/clinical-write.R tests/testthat/test-clinical-write.R NAMESPACE man/viya_clinical_upload.Rd
git commit -m "Add viya_clinical_upload() for new Clinical Repository files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `viya_clinical_delete()`

**Files:**
- Modify: `R/clinical-write.R` (append)
- Modify: `tests/testthat/test-clinical-write.R` (append)

**Interfaces:**
- Consumes: `.viya_clinical_split()`, `.viya_clinical_item_uri()` (Task 1); test helpers (Task 1).
- Produces: `viya_clinical_delete(path, permanent = FALSE, token, url)` → the deleted item's metadata as it was before deletion, invisibly. Task 6's folder helper uses it for cleanup.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-clinical-write.R`:

```r
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: the 4 new tests fail with `could not find function "viya_clinical_delete"`.

- [ ] **Step 3: Write `viya_clinical_delete()`**

Append to `R/clinical-write.R`:

```r
#' Delete a Clinical Repository item
#'
#' By default, moves a file or folder to the recycle bin, where it can be
#' recovered. A folder is deleted with everything in it, but not while any
#' file inside is checked out -- undo or check in those first.
#'
#' Contexts (organizations, studies, ...) can't go to the recycle bin, so
#' deleting one needs `permanent = TRUE`, and the "Permanently Delete Items"
#' privilege.
#'
#' @param path Repository path of the item to delete.
#' @param permanent Delete for good instead of moving to the recycle bin.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The item's metadata as it was before deletion, invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_delete("/Acme/Study 1/programs/old.sas")
#' }
#' @export
viya_clinical_delete <- function(path, permanent = FALSE,
                                 token = viya_token(),
                                 url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  .viya_clinical_split(path)  # rejects the root and relative paths
  it <- viya_clinical_item(path, token, url)
  # Found live: the server answers "Context types cannot be logically
  # deleted" here; say what to do instead.
  if (identical(it$primaryType, "CONTEXT") && !isTRUE(permanent))
    stop("'", path, "' is a context, and contexts can't go to the recycle ",
         "bin. Pass permanent = TRUE to delete it for good (needs the ",
         "\"Permanently Delete Items\" privilege).")
  .viya_req(h, paste0(.viya_clinical_item_uri(it$id),
                      if (isTRUE(permanent)) "?permanent=true" else "")) |>
    httr2::req_method("DELETE") |> httr2::req_perform()
  message("deleted ", path,
          if (isTRUE(permanent)) " permanently" else " (to the recycle bin)")
  invisible(it)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: `FAIL 0`.

- [ ] **Step 5: Regenerate docs and commit**

```bash
Rscript -e 'roxygen2::roxygenise()'
git add R/clinical-write.R tests/testthat/test-clinical-write.R NAMESPACE man/viya_clinical_delete.Rd
git commit -m "Add viya_clinical_delete()

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `viya_clinical_update()` (rename / edit description)

**Files:**
- Modify: `R/clinical-write.R` (append)
- Modify: `tests/testthat/test-clinical-write.R` (append)

**Interfaces:**
- Consumes: `.viya_clinical_item_uri()` (Task 1); test helpers (Task 1). The mock answers `GET /clinicalRepository/repository/items/<id>` with header `ETag: "etag-1"`.
- Produces: `viya_clinical_update(path, name = NULL, description = NULL, token, url)` → the updated item list (from the `PATCH` response), invisibly.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-clinical-write.R`:

```r
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: the 4 new tests fail with `could not find function "viya_clinical_update"`.

- [ ] **Step 3: Write `viya_clinical_update()`**

Append to `R/clinical-write.R`:

```r
#' Rename a Clinical Repository item or edit its description
#'
#' Changes an item's name, its description, or both. The item stays where
#' it is; a rename can't move it to another container.
#'
#' @param path Repository path of the item.
#' @param name New name, without any `/`. `NULL` (the default) leaves the
#'   name unchanged.
#' @param description New description. `NULL` (the default) leaves it
#'   unchanged.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The updated item's metadata (see [viya_clinical_item()]),
#'   invisibly. After a rename, its `path` is the new path.
#' @examples
#' \dontrun{
#' viya_clinical_update("/Acme/Study 1/programs/adsl.sas", name = "adsl_v1.sas")
#' viya_clinical_update("/Acme/Study 1", description = "Phase III, ADaM 1.3")
#' }
#' @export
viya_clinical_update <- function(path, name = NULL, description = NULL,
                                 token = viya_token(),
                                 url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(path))
  if (is.null(name) && is.null(description))
    stop("give `name`, `description`, or both")
  if (!is.null(name) &&
      (!is.character(name) || length(name) != 1 || !nzchar(name) ||
       grepl("/", name, fixed = TRUE)))
    stop("`name` must be a bare item name, without '/'")
  if (!is.null(description))
    stopifnot(is.character(description), length(description) == 1)
  body <- Filter(Negate(is.null), list(name = name, description = description))

  it  <- viya_clinical_item(path, token, url)
  uri <- .viya_clinical_item_uri(it$id)
  # Found live: PATCH without If-Match is refused with 428, so read the
  # item's current ETag first -- the same read-then-write as viya_fs_delete().
  etag <- .viya_req(h, uri) |> httr2::req_perform() |>
    httr2::resp_header("ETag")
  out <- .viya_req(h, uri) |>
    httr2::req_method("PATCH") |>
    httr2::req_headers(`If-Match` = etag) |>
    httr2::req_body_json(body) |>
    httr2::req_perform() |> httr2::resp_body_json()
  message("updated ", out$path %||% path)
  invisible(out)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: `FAIL 0`.

- [ ] **Step 5: Regenerate docs and commit**

```bash
Rscript -e 'roxygen2::roxygenise()'
git add R/clinical-write.R tests/testthat/test-clinical-write.R NAMESPACE man/viya_clinical_update.Rd
git commit -m "Add viya_clinical_update() to rename items and edit descriptions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Check out, check in, undo check-out

**Files:**
- Modify: `R/clinical-write.R` (append)
- Modify: `tests/testthat/test-clinical-write.R` (append)

**Interfaces:**
- Consumes: `.viya_clinical_enc()` (Task 1); `viya_clinical_download(path, local_path, token, url)` (existing, `R/clinical.R`); test helpers (Task 1). The mock answers `POST .../items/<id>/content` with body `"v1\n"` and `Content-Type: application/x-sas`, and answers `UNDO_CHECKOUT` with an empty `200`.
- Produces:
  - `.viya_clinical_ws_action(h, path, action, comment = NULL)` → `NULL`, invisibly
  - `viya_clinical_checkout(path, local_path = NULL, overwrite = FALSE, token, url)` → refreshed item list, invisibly
  - `viya_clinical_checkin(path, local_path, comment = NULL, token, url)` → refreshed item list, invisibly
  - `viya_clinical_undo_checkout(path, token, url)` → refreshed item list, invisibly

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-clinical-write.R`:

```r
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
  expect_equal(put$body$data$file$path, src)
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: the 8 new tests fail with `could not find function "viya_clinical_checkout"` (or `_checkin`, `_undo_checkout`).

- [ ] **Step 3: Write the three functions and their helper**

Append to `R/clinical-write.R`:

```r
# The one workspace request behind check-out, check-in and undo. Found
# live: workspace paths mirror repository paths, so the repository path is
# passed through as-is.
.viya_clinical_ws_action <- function(h, path, action, comment = NULL) {
  q <- paste0("/clinicalRepository/workspaces/@currentUser/files?path=",
              .viya_clinical_enc(path), "&action=", action)
  if (!is.null(comment)) q <- paste0(q, "&comment=", .viya_clinical_enc(comment))
  .viya_req(h, q) |> httr2::req_method("POST") |> httr2::req_perform()
  invisible(NULL)
}

#' Check out a Clinical Repository file
#'
#' Checks a file out to you, so others can't check in changes to it until
#' you check it back in ([viya_clinical_checkin()]) or undo the check-out
#' ([viya_clinical_undo_checkout()]). Give `local_path` to download the
#' file at the same time.
#'
#' @param path Repository path of the file.
#' @param local_path Where to download the file. `NULL` (the default)
#'   checks the file out without downloading it.
#' @param overwrite Replace `local_path` if it already exists. `FALSE` by
#'   default, so local edits aren't lost.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The file's metadata after check-out (see
#'   [viya_clinical_item()]), invisibly. `checkedOut` is `TRUE` and
#'   `checkedOutBy` names you.
#' @examples
#' \dontrun{
#' viya_clinical_checkout("/Acme/Study 1/programs/adsl.sas", "adsl.sas")
#' # ...edit adsl.sas...
#' viya_clinical_checkin("/Acme/Study 1/programs/adsl.sas", "adsl.sas",
#'                       comment = "Derive TRTSDT from EX")
#' }
#' @export
viya_clinical_checkout <- function(path, local_path = NULL, overwrite = FALSE,
                                   token = viya_token(),
                                   url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(path))
  if (!is.null(local_path)) {
    stopifnot(is.character(local_path), length(local_path) == 1,
              nzchar(local_path))
    if (file.exists(local_path) && !isTRUE(overwrite))
      stop("'", local_path, "' already exists; pass overwrite = TRUE to ",
           "replace it")
  }
  .viya_clinical_ws_action(h, path, "CHECK_OUT")
  if (!is.null(local_path)) viya_clinical_download(path, local_path, token, url)
  message("checked out ", path)
  invisible(viya_clinical_item(path, token, url))
}

#' Check in a Clinical Repository file
#'
#' Uploads your local copy of a checked-out file and checks it in,
#' replacing the repository's content and releasing the check-out.
#'
#' @param path Repository path of the file. It must be checked out to you
#'   (see [viya_clinical_checkout()]).
#' @param local_path Path of the local copy to check in.
#' @param comment Optional check-in comment, stored on the file.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The file's metadata after check-in (see [viya_clinical_item()]),
#'   invisibly. `fileComment` holds `comment`.
#' @inherit viya_clinical_checkout examples
#' @export
viya_clinical_checkin <- function(path, local_path, comment = NULL,
                                  token = viya_token(),
                                  url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(path), is.character(local_path), length(local_path) == 1)
  if (!file.exists(local_path)) stop("'", local_path, "' does not exist")
  if (!is.null(comment)) stopifnot(is.character(comment), length(comment) == 1)

  it <- viya_clinical_item(path, token, url)
  if (!isTRUE(it$checkedOut))
    stop("'", path, "' is not checked out; call viya_clinical_checkout() ",
         "first")
  # Found live: check-in reads the file from your workspace, so the local
  # copy goes there first. CHECK_OUT already created the workspace folders.
  .viya_req(h, paste0("/clinicalRepository/workspaces/@currentUser/items?path=",
                      .viya_clinical_enc(path))) |>
    httr2::req_method("PUT") |>
    httr2::req_body_multipart(
      file = curl::form_file(local_path, name = basename(path))) |>
    httr2::req_perform()
  .viya_clinical_ws_action(h, path, "CHECK_IN", comment = comment)
  message("checked in ", path)
  invisible(viya_clinical_item(path, token, url))
}

#' Undo a Clinical Repository check-out
#'
#' Releases your check-out of a file without changing the repository's
#' copy. Local files are untouched.
#'
#' @param path Repository path of the file.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The file's metadata afterwards (see [viya_clinical_item()]),
#'   invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_undo_checkout("/Acme/Study 1/programs/adsl.sas")
#' }
#' @export
viya_clinical_undo_checkout <- function(path, token = viya_token(),
                                        url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(path))
  .viya_clinical_ws_action(h, path, "UNDO_CHECKOUT")
  message("undid check-out of ", path)
  invisible(viya_clinical_item(path, token, url))
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-clinical-write.R")'`
Expected: `FAIL 0`.

Then run the full unit suite:
Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_dir("tests/testthat")'`
Expected: `FAIL 0` (live tests skip).

- [ ] **Step 5: Regenerate docs and commit**

```bash
Rscript -e 'roxygen2::roxygenise()'
git add R/clinical-write.R tests/testthat/test-clinical-write.R NAMESPACE man/viya_clinical_checkout.Rd man/viya_clinical_checkin.Rd man/viya_clinical_undo_checkout.Rd
git commit -m "Add check-out, check-in and undo for Clinical Repository files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Live tests

**Files:**
- Modify: `tests/testthat/helper-live.R` (append)
- Create: `tests/testthat/test-live-clinical-write.R`

**Interfaces:**
- Consumes: every function from Tasks 1-5; `skip_if_no_clinical()` (existing, `helper-live.R`); `viya_clinical_item()`, `viya_clinical_list()`, `viya_clinical_download()` (existing).
- Produces: `.viya_live_clinical_org` (`"/viyar_live_tests"`) and `local_clinical_folder(env = parent.frame())` → path of a fresh, empty folder that is deleted when `env` exits.

**Credentials.** This task runs against a real cluster. The controller session holds a token in a private scratch file; export it like this (do not print it, and do not copy it anywhere else):

```bash
S=/private/tmp/claude-502/-Users-samiul-Documents-viyar-viyar/7a90a1cb-1619-4ba7-b1f5-97a4dd8a0b83/scratchpad
export VIYA_URL=https://caf.pcluster.soleng.posit.it VIYA_TOKEN=$(cat $S/viya_token)
```

The token expires at 2026-10-02 05:58 UTC. If the live run fails with `401`, or every live test skips with "no Viya token available", **stop and report back**. Don't try to log in.

- [ ] **Step 1: Add the fixture helper**

Append to `tests/testthat/helper-live.R`:

```r
# Clinical write tests share one long-lived organization. The test account
# can create an organization but not delete one (contexts need permanent
# deletion, a privilege it lacks -- found live), so a run must never create
# a new one. Each test instead gets its own folder inside it, deleted when
# the test ends. A deleted folder goes to the recycle bin.
.viya_live_clinical_org <- "/viyar_live_tests"

local_clinical_folder <- function(env = parent.frame()) {
  have_org <- tryCatch({
    viya_clinical_item(.viya_live_clinical_org)
    TRUE
  }, error = function(e) FALSE)
  if (!have_org)
    viya_clinical_create(.viya_live_clinical_org, "organization")
  path <- paste0(.viya_live_clinical_org, "/run_",
                 format(Sys.time(), "%Y%m%d_%H%M%S"), "_",
                 sample.int(1e6, 1))
  viya_clinical_create(path)
  # Found live: a folder holding a checked-out file can't be deleted, so a
  # test that checks a file out must defer its own undo. Deferred calls run
  # last-in-first-out, so that undo runs before this delete.
  withr::defer(try(viya_clinical_delete(path), silent = TRUE), envir = env)
  path
}
```

- [ ] **Step 2: Write the live tests**

Create `tests/testthat/test-live-clinical-write.R`:

```r
test_that("create, upload, list, download and delete round-trip", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()

  sub <- paste0(dir, "/programs")
  it <- viya_clinical_create(sub)
  expect_equal(it$primaryType, "FOLDER")
  expect_equal(it$path, sub)

  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("proc print data=sashelp.class; run;", src)
  f <- viya_clinical_upload(src, sub, name = "print.sas")
  expect_equal(f$path, paste0(sub, "/print.sas"))
  expect_equal(f$typeId, "sasprogram")

  df <- viya_clinical_list(sub)
  expect_equal(df$name, "print.sas")
  expect_equal(df$size, file.size(src))

  out <- withr::local_tempfile(fileext = ".sas")
  viya_clinical_download(f$path, out)
  expect_equal(readLines(out), readLines(src))

  viya_clinical_delete(f$path)
  expect_equal(nrow(viya_clinical_list(sub)), 0)
})

test_that("check out, edit, then check in with a comment", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* v1 */", src)
  f <- viya_clinical_upload(src, dir, name = "adsl.sas")

  local <- withr::local_tempfile(fileext = ".sas")
  it <- viya_clinical_checkout(f$path, local)
  withr::defer(try(viya_clinical_undo_checkout(f$path), silent = TRUE))
  expect_true(it$checkedOut)
  expect_true(nzchar(it$checkedOutBy))
  expect_equal(readLines(local), "/* v1 */")

  writeLines("/* v2 */", local)
  it <- viya_clinical_checkin(f$path, local, comment = "v2 from viyar live test")
  expect_false(it$checkedOut)
  expect_equal(it$fileComment, "v2 from viyar live test")

  back <- withr::local_tempfile(fileext = ".sas")
  viya_clinical_download(f$path, back)
  expect_equal(readLines(back), "/* v2 */")
})

test_that("undo check-out releases the file, and misuse gets a clear error", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* v1 */", src)
  f <- viya_clinical_upload(src, dir, name = "adae.sas")

  it <- viya_clinical_checkout(f$path)
  withr::defer(try(viya_clinical_undo_checkout(f$path), silent = TRUE))
  expect_true(it$checkedOut)
  expect_error(viya_clinical_checkout(f$path), "already checked out")

  it <- viya_clinical_undo_checkout(f$path)
  expect_false(it$checkedOut)
  expect_error(viya_clinical_undo_checkout(f$path), "not currently checked out")
  expect_error(viya_clinical_checkin(f$path, src), "not checked out")
})

test_that("update renames a file and edits its description", {
  skip_if_no_clinical()
  dir <- local_clinical_folder()
  src <- withr::local_tempfile(fileext = ".sas")
  writeLines("/* a */", src)
  f <- viya_clinical_upload(src, dir, name = "a.sas")

  it <- viya_clinical_update(f$path, name = "b.sas",
                             description = "renamed by viyar")

  expect_equal(it$name, "b.sas")
  expect_equal(it$path, paste0(dir, "/b.sas"))
  expect_equal(it$description, "renamed by viyar")
  expect_error(viya_clinical_item(f$path), "No resource with the path")
})

test_that("a context can't be deleted without permanent = TRUE", {
  skip_if_no_clinical()
  local_clinical_folder()  # makes sure the test organization exists

  expect_error(viya_clinical_delete(.viya_live_clinical_org),
               "permanent = TRUE")
  expect_no_error(viya_clinical_item(.viya_live_clinical_org))
})
```

- [ ] **Step 3: Run the live tests**

Export the credentials (see above), then:

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_file("tests/testthat/test-live-clinical-write.R")'`
Expected: `FAIL 0 | SKIP 0`. If a test fails, fix the **code** (Tasks 1-5) only when the failure shows the code disagrees with the live behaviour recorded in the spec; if the live behaviour itself differs from the spec, stop and report back with the exact server message.

- [ ] **Step 4: Check that nothing was left behind**

Run:
```bash
Rscript -e 'pkgload::load_all(".", quiet = TRUE); print(viya_clinical_list("/viyar_live_tests")[, c("name", "type")])'
```
Expected: zero rows. A leftover `run_*` folder means a deferred cleanup failed; find out why before committing.

- [ ] **Step 5: Run the full suite, then commit**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_dir("tests/testthat")'` (credentials still exported)
Expected: `FAIL 0`.

```bash
git add tests/testthat/helper-live.R tests/testthat/test-live-clinical-write.R
git commit -m "Add live tests for Clinical Repository writes

Each test works in its own folder inside one long-lived organization,
/viyar_live_tests, and deletes it afterwards. A run never creates another
organization: the test account can't delete one.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: README and CLAUDE.md

**Files:**
- Modify: `README.md` (the "SAS Clinical Acceleration Repository" section)
- Modify: `CLAUDE.md` (the `R/clinical.R` architecture entry and its sub-bullets)

**Interfaces:**
- Consumes: the function names and behaviour from Tasks 1-5.
- Produces: documentation only.

- [ ] **Step 1: Update the README**

In `README.md`, replace this sentence in the Clinical Acceleration section:

```
Writing to the
repository (creating contexts, uploading files) is out of scope here:
this release is read-only.
```

with:

```
Writing is covered below.
```

Then insert this block immediately before the paragraph that starts `If you already have a compute session`:

````markdown
### Changing repository content

Add new files with `viya_clinical_upload()`. To change an existing file,
check it out, edit your local copy, and check it back in:

```r
viya_clinical_create("/Acme/Study 1/programs")          # a folder
viya_clinical_upload("adsl.sas", "/Acme/Study 1/programs")

f <- "/Acme/Study 1/programs/adsl.sas"
viya_clinical_checkout(f, "adsl.sas", overwrite = TRUE)
# ...edit adsl.sas...
viya_clinical_checkin(f, "adsl.sas", comment = "Derive TRTSDT from EX")
viya_clinical_undo_checkout(f)                          # or give up instead

viya_clinical_update(f, name = "adsl_v1.sas")           # rename
viya_clinical_delete("/Acme/Study 1/programs/adsl_v1.sas")  # to the recycle bin
```

What you can do depends on your repository permissions. Creating a
top-level organization needs Clinical Administrators membership, and
deleting a context needs `permanent = TRUE` plus the "Permanently Delete
Items" privilege. A deployment can also refuse some file extensions; the
error message names the extension.
````

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`, inside the `R/clinical.R` entry:

1. Replace `Read
  only in this release -- no create/upload/delete.` with `Read-only;
  writes live in \`R/clinical-write.R\` (next entry).`
2. Replace the line `  - **live** Writes (all confirmed 2026-10-01 with a Clinical
    Administrators account on \`caf\`; none are wrapped yet):` with `  - **live** Writes (all confirmed 2026-10-01 with a Clinical
    Administrators account on \`caf\`; wrapped in \`R/clinical-write.R\`):`

Then add a new entry directly after the whole `R/clinical.R` entry (before the `R/quarto.R` entry):

```markdown
- `R/clinical-write.R` — `viya_clinical_create()`/`_upload()`/
  `_checkout()`/`_checkin()`/`_undo_checkout()`/`_update()`/`_delete()`:
  writes to the Clinical Repository, built on the request shapes listed
  under `R/clinical.R` above. Check-out and check-in go through the
  server's per-user workspace, which the API never exposes:
  `viya_clinical_checkin()` uploads the local copy to the workspace path
  that mirrors the repository path, then sends `CHECK_IN`. It checks
  `checkedOut` first, so it never touches the workspace for a file that
  isn't checked out. `viya_clinical_update()` reads the item's `ETag` and
  sends it as `If-Match` (a `PATCH` without it gets `428`); the body is
  flat (`{"name": ...}`). Found live: `CHECK_OUT` of a file you already
  hold gets `409`, and `CHECK_IN`/`UNDO_CHECKOUT` of a file that isn't
  checked out gets `400`; a folder holding a checked-out file can't be
  deleted (`400 The file is checked out`).
  **Lock/unlock is not implemented, deliberately:** items carry a
  `locked` field and there is a "Manage Locking" privilege, but
  `PATCH {"locked": true}` answers `400 Property "locked" is not a valid
  property`, `.../lock`, `.../locked` and `.../state?value=locked` all
  `404`, and the OpenAPI spec defines no lock action. Version history
  (`/versions`) is being built on a separate branch. Live tests
  (`test-live-clinical-write.R`) work inside one long-lived organization,
  `/viyar_live_tests`, one folder per test, because the test account
  can't delete an organization.
```

- [ ] **Step 3: Verify, then commit**

Run: `Rscript -e 'pkgload::load_all(".", quiet = TRUE); testthat::test_dir("tests/testthat")'`
Expected: `FAIL 0`.

Run: `grep -n "read-only\|none are wrapped" README.md CLAUDE.md`
Expected: no line claims the Clinical Repository support is read-only or unwrapped (the `R/clinical.R` entry may say "Read-only; writes live in ...").

```bash
git add README.md CLAUDE.md
git commit -m "Document Clinical Repository write support

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
