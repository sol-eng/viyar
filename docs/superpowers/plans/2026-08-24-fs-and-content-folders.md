# viyar: Folder Creation + OS-Filesystem Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `viya_create_folder()` for SAS Content, and a new `R/fs.R`
with `viya_fs_mkdir()`/`viya_fs_upload()`/`viya_fs_download()`/
`viya_fs_list()` for the OS-level filesystem a compute session sees.

**Architecture:** SAS Content folder creation reuses the existing
`.viya_folder()` helper and walks the target path one segment at a time
(the Folders API has no recursive create). The OS-filesystem functions
are a new file, `R/fs.R`, built around a shared `.viya_fs_escape()`
helper (converts `/` to SAS's `~fs~` URL convention) and `.viya_fs_exists()`
(existence check via a 404-tolerant GET), with `viya_fs_mkdir()` walking
segments the same way. All four `viya_fs_*` functions require an active
compute session (`h$session`), unlike the SAS Content functions.

**Tech Stack:** R (>= 4.1.0), httr2, testthat 3e (mocked + live tiers,
matching the rest of the package).

**Spec:** `docs/superpowers/specs/2026-08-24-fs-and-content-folders-design.md`

## Global Constraints

- Every endpoint detail in this plan (parent-vs-leaf semantics for
  creation, the `~fs~` path escaping, no server-side recursive create,
  upload/download/list request-response shapes) was verified live against
  `https://viya.pcluster.soleng.posit.it` before being written down — the
  code below is a transcription of already-working code, not a draft.
- Follow existing code style exactly: base-pipe (`|>`), `httr2::`/
  `utils::` fully-qualified calls (no `library()` calls in R/ files),
  `message()` for user-facing progress, `stopifnot()` for input
  validation, roxygen2 doc blocks on every exported function.
- Delivery: commits land on the current branch, `robustness-auth-and-tests`
  (already the source of open PR #1) — no new branch.
- Tests run via `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`.
- Delete/rename/copy operations on either system are explicitly out of
  scope for this plan (not requested).

---

## Task 1: `viya_create_folder()` for SAS Content

**Files:**
- Modify: `R/files.R` (append)
- Create: `tests/testthat/test-files.R`

**Interfaces:**
- Consumes: `.viya_folder(h, folder_path)` (existing helper, `R/files.R`,
  throws on a non-existent path), `.viya_req(h, path)` (existing,
  `R/utils.R`).
- Produces: `.viya_folder_or_null(h, folder_path)` (like `.viya_folder()`
  but returns `NULL` instead of throwing when the path doesn't exist —
  used by Task 1 only, but kept as its own helper for clarity),
  `viya_create_folder(h, path)` (exported; returns the leaf folder's
  resource info, invisibly). Used standalone; no later task depends on
  it.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-files.R`:

```r
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
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `viya_create_folder`/`.viya_folder_or_null` not found.

- [ ] **Step 3: Implement**

Append to `R/files.R`:

```r
.viya_folder_or_null <- function(h, folder_path) {
  tryCatch(.viya_folder(h, folder_path), error = function(e) NULL)
}

#' Create a folder in SAS Content (the Files/Folders service)
#'
#' Creates every missing folder along `path`, one level at a time -- the
#' Folders API has no recursive/nested create, so e.g.
#' `viya_create_folder(h, "/Public/Reports/2026")` creates `Reports`
#' under `/Public` first if it's missing, then `2026` under that.
#' Already-existing segments are left untouched (safe to call repeatedly).
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param path Full Viya folder path to create, e.g. `"/Public/Reports"`.
#' @return The final (leaf) folder's resource info, invisibly.
#' @examples
#' \dontrun{
#' viya_create_folder(h, "/Public/Reports/2026")
#' }
#' @export
viya_create_folder <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(path))
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  if (!length(segments)) stop("path must have at least one segment")

  parent_id <- NULL
  fld <- NULL
  for (i in seq_along(segments)) {
    partial <- paste0("/", paste(segments[seq_len(i)], collapse = "/"))
    fld <- .viya_folder_or_null(h, partial)
    if (is.null(fld)) {
      parent_uri <- if (is.null(parent_id)) "none"
                    else paste0("/folders/folders/", parent_id)
      fld <- .viya_req(h, paste0("/folders/folders?parentFolderUri=",
                                 utils::URLencode(parent_uri, reserved = TRUE))) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(name = segments[i])) |>
        httr2::req_perform() |> httr2::resp_body_json()
      message("created folder ", partial)
    }
    parent_id <- fld$id
  }
  invisible(fld)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (3 new test blocks, all green; total suite count increases
by 3 over the current baseline).

- [ ] **Step 5: Commit**

```bash
git add R/files.R tests/testthat/test-files.R
git commit -m "Add viya_create_folder() for SAS Content, walking missing path segments"
```

---

## Task 2: `R/fs.R` foundations — path escaping, existence check, `viya_fs_mkdir()`

**Files:**
- Create: `R/fs.R`
- Create: `tests/testthat/test-fs.R`

**Interfaces:**
- Consumes: `.viya_req(h, path)` (existing, `R/utils.R`).
- Produces: `.viya_fs_escape(path)` (character -> character, converts
  `/`-separated segments to SAS's `~fs~`-joined URL convention),
  `.viya_fs_exists(h, path)` (character -> logical, tolerant of 404),
  `viya_fs_mkdir(h, path)` (exported; returns `path` invisibly). Used by
  Tasks 3 and 4 (`.viya_fs_escape()` specifically).

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-fs.R`:

```r
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
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.viya_fs_escape`/`.viya_fs_exists`/`viya_fs_mkdir` not found.

- [ ] **Step 3: Implement**

Create `R/fs.R`:

```r
.viya_fs_escape <- function(path) {
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  paste(segments, collapse = "~fs~")
}

.viya_fs_exists <- function(h, path) {
  tryCatch({
    .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                        .viya_fs_escape(path))) |>
      httr2::req_perform()
    TRUE
  }, error = function(e) FALSE)
}

#' Create a directory on a compute session's filesystem
#'
#' Unlike [viya_create_folder()] (SAS Content), this creates a real
#' directory on the OS filesystem the compute session sees -- a home
#' directory, an NFS-mounted shared path, or any path the session process
#' can write to. Creates every missing intermediate directory along
#' `path`, one level at a time (there is no server-side recursive
#' create). Already-existing segments are left untouched (safe to call
#' repeatedly).
#'
#' @param h A `viyar` handle from [viya_session()] (must have an active
#'   compute session -- this operates on that session's filesystem).
#' @param path Directory path to create, e.g.
#'   `"/gel/homes/samiul/reports/2026"`. A relative path is resolved
#'   against the session's current working directory.
#' @return `path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_mkdir(h, "/gel/homes/samiul/reports/2026")
#' }
#' @export
viya_fs_mkdir <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(path))
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  if (!length(segments)) stop("path must have at least one segment")

  for (i in seq_along(segments)) {
    partial <- paste(segments[seq_len(i)], collapse = "/")
    if (!.viya_fs_exists(h, partial)) {
      parent <- if (i == 1) "." else paste(segments[seq_len(i - 1)], collapse = "/")
      .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                          .viya_fs_escape(parent))) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(name = segments[i], isDirectory = TRUE)) |>
        httr2::req_perform()
      message("created directory ", partial)
    }
  }
  invisible(path)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (4 new test blocks, all green).

- [ ] **Step 5: Commit**

```bash
git add R/fs.R tests/testthat/test-fs.R
git commit -m "Add viya_fs_mkdir() for the OS-level filesystem a compute session sees"
```

---

## Task 3: `viya_fs_upload()` / `viya_fs_download()`

**Files:**
- Modify: `R/fs.R` (append)
- Modify: `tests/testthat/test-fs.R` (append)

**Interfaces:**
- Consumes: `.viya_fs_escape()` (Task 2).
- Produces: `viya_fs_upload(h, local_path, remote_path)` (exported,
  returns `remote_path` invisibly), `viya_fs_download(h, remote_path,
  local_path)` (exported, returns `local_path` invisibly).

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-fs.R`:

```r
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
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `viya_fs_upload`/`viya_fs_download` not found.

- [ ] **Step 3: Implement**

Append to `R/fs.R`:

```r
#' Upload a local file to a compute session's filesystem
#'
#' Unlike [viya_upload()] (which uploads to SAS Content), this writes
#' directly to the OS filesystem the compute session sees.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param local_path Path of the local file.
#' @param remote_path Destination path on the session's filesystem, e.g.
#'   `"/gel/homes/samiul/report.csv"`.
#' @return `remote_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_upload(h, "report.html", "/gel/homes/samiul/report.html")
#' }
#' @export
viya_fs_upload <- function(h, local_path, remote_path) {
  stopifnot(inherits(h, "viyar"), file.exists(local_path), nzchar(remote_path))
  .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                      .viya_fs_escape(remote_path), "/content")) |>
    httr2::req_method("PUT") |>
    httr2::req_headers(`Content-Type` = "application/octet-stream") |>
    httr2::req_body_file(local_path) |>
    httr2::req_perform()
  message("uploaded '", local_path, "' -> ", remote_path)
  invisible(remote_path)
}

#' Download a file from a compute session's filesystem
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param remote_path Path on the session's filesystem, e.g.
#'   `"/gel/homes/samiul/report.csv"`.
#' @param local_path Local destination path.
#' @return `local_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_download(h, "/gel/homes/samiul/report.csv", "report.csv")
#' }
#' @export
viya_fs_download <- function(h, remote_path, local_path) {
  stopifnot(inherits(h, "viyar"), nzchar(remote_path))
  .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                      .viya_fs_escape(remote_path), "/content")) |>
    httr2::req_perform() |> httr2::resp_body_raw() |>
    writeBin(local_path)
  message("downloaded ", remote_path, " -> ", local_path)
  invisible(local_path)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (3 new test blocks, all green).

- [ ] **Step 5: Commit**

```bash
git add R/fs.R tests/testthat/test-fs.R
git commit -m "Add viya_fs_upload()/viya_fs_download() for direct OS-filesystem transfer"
```

---

## Task 4: `viya_fs_list()`

**Files:**
- Modify: `R/fs.R` (append)
- Modify: `tests/testthat/test-fs.R` (append)

**Interfaces:**
- Consumes: `.viya_fs_escape()` (Task 2).
- Produces: `viya_fs_list(h, path)` (exported; returns a data.frame with
  columns `name`, `isDirectory`, `size`, `path`).

- [ ] **Step 1: Write the failing test**

Append to `tests/testthat/test-fs.R`:

```r
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
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `viya_fs_list` not found.

- [ ] **Step 3: Implement**

Append to `R/fs.R`:

```r
#' List a directory's contents on a compute session's filesystem
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param path Directory path on the session's filesystem.
#' @return A data frame with columns `name`, `isDirectory`, `size`, `path`.
#' @examples
#' \dontrun{
#' viya_fs_list(h, "/gel/homes/samiul")
#' }
#' @export
viya_fs_list <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(path))
  r <- .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                           .viya_fs_escape(path), "/members?limit=500")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(
    name = vapply(r$items, `[[`, "", "name"),
    isDirectory = vapply(r$items, `[[`, logical(1), "isDirectory"),
    size = vapply(r$items, function(x) x$size %||% NA_real_, numeric(1)),
    path = vapply(r$items, `[[`, "", "path"))
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (1 new test block, all green).

- [ ] **Step 5: Commit**

```bash
git add R/fs.R tests/testthat/test-fs.R
git commit -m "Add viya_fs_list() for directory listings on the OS-level filesystem"
```

---

## Task 5: Docs regen + README/CLAUDE.md updates

**Files:**
- Modify: `NAMESPACE` (regenerated, not hand-edited)
- Modify/Create: `man/*.Rd` (regenerated, not hand-edited)
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: all roxygen2 doc blocks written in Tasks 1-4.

- [ ] **Step 1: Regenerate**

Run: `Rscript -e 'roxygen2::roxygenise()'`
Expected: `NAMESPACE` gains `export(viya_create_folder)`,
`export(viya_fs_mkdir)`, `export(viya_fs_upload)`,
`export(viya_fs_download)`, `export(viya_fs_list)` (alphabetically
ordered among the existing exports); `man/viya_create_folder.Rd`,
`man/viya_fs_mkdir.Rd`, `man/viya_fs_upload.Rd`,
`man/viya_fs_download.Rd`, `man/viya_fs_list.Rd` created.

- [ ] **Step 2: Update `README.md`**

Add a new section after the existing "## Quick start" section (before
"## Authenticating to SAS Viya"):

```markdown
## Folders and files

Two separate storage systems, two separate function families:

- **SAS Content** (the Files/Folders app in Viya): `viya_create_folder()`,
  `viya_upload()`, `viya_download()`.
- **The compute session's own filesystem** (a home directory, an
  NFS-mounted shared path, or anything else the session process can see
  on disk): `viya_fs_mkdir()`, `viya_fs_upload()`, `viya_fs_download()`,
  `viya_fs_list()`. These need an active compute session (`h`) and
  operate on that session's real filesystem, not the Files/Folders app.

```r
viya_create_folder(h, "/Public/Reports/2026")
viya_upload(h, "report.html", "/Public/Reports/2026")

viya_fs_mkdir(h, "/gel/homes/samiul/reports/2026")
viya_fs_upload(h, "report.html", "/gel/homes/samiul/reports/2026/report.html")
viya_fs_list(h, "/gel/homes/samiul/reports/2026")
```
```

- [ ] **Step 3: Update `CLAUDE.md`**

In the "## Architecture" section, update the `R/files.R` bullet and add a
new bullet for `R/fs.R`:

Find:
```markdown
- `R/files.R` — `viya_upload()`/`viya_download()` (Viya Files/Folders).
```

Replace with:
```markdown
- `R/files.R` — `viya_upload()`/`viya_download()`/`viya_create_folder()`
  (SAS Content: the Files/Folders service).
- `R/fs.R` — `viya_fs_mkdir()`/`viya_fs_upload()`/`viya_fs_download()`/
  `viya_fs_list()`: a second, distinct storage system -- the real OS
  filesystem a compute session sees (home directory, NFS-mounted shared
  paths, etc.), via the Compute service's own "File System" REST
  resource. Every path segment embedded in a URL for these calls has each
  `/` replaced with the literal `~fs~` (SAS's own escaping convention,
  confirmed empirically, not documented in prose form anywhere). Neither
  this API nor the Folders API supports recursive/nested creation --
  `viya_create_folder()`/`viya_fs_mkdir()` both walk the path themselves,
  creating one missing segment at a time.
```

- [ ] **Step 4: Verify the package still loads cleanly**

Run: `Rscript -e 'pkgload::load_all("."); cat("loaded ok\n")'`
Expected: `loaded ok` with no errors.

- [ ] **Step 5: Commit**

```bash
git add NAMESPACE man/ README.md CLAUDE.md
git commit -m "Regenerate docs for the new folder/fs functions and update README/CLAUDE.md"
```

---

## Task 6: Live test suite (requires a live cluster — ask the user which URL to use)

**This task must be run with a real Viya cluster, since it validates
against the actual REST APIs, not mocks. Per standing project policy, do
not assume or default to any specific cluster — ask the user which
`VIYA_URL`/token to use before running.**

**Files:**
- Create: `tests/testthat/test-live-fs.R`

**Interfaces:**
- Consumes: `skip_if_no_viya()` (existing helper, `tests/testthat/helper-live.R`),
  every function built in Tasks 1-4.

- [ ] **Step 1: Write the live test file**

Create `tests/testthat/test-live-fs.R`:

```r
test_that("viya_create_folder creates nested SAS Content folders, idempotently", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  path <- paste0("/Public/viyar_live_test_", as.integer(Sys.time()))
  fld <- viya_create_folder(h, paste0(path, "/nested/deep"))
  expect_equal(fld$name, "deep")

  # idempotent: re-running creates nothing new and doesn't error
  fld2 <- viya_create_folder(h, paste0(path, "/nested/deep"))
  expect_equal(fld2$id, fld$id)

  # cleanup: delete the whole test tree from SAS Content
  root <- .viya_folder(h, path)
  .viya_req(h, paste0("/folders/folders/", root$id, "?recursive=true")) |>
    httr2::req_method("DELETE") |> httr2::req_perform()
})

test_that("viya_fs_mkdir/upload/download/list round-trip on the OS filesystem", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  base <- paste0("viyar_live_test_", as.integer(Sys.time()))
  viya_fs_mkdir(h, paste0(base, "/a/b"))

  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar fs live test", tmp_up)
  viya_fs_upload(h, tmp_up, paste0(base, "/a/hello.txt"))

  tmp_down <- tempfile(fileext = ".txt")
  viya_fs_download(h, paste0(base, "/a/hello.txt"), tmp_down)
  expect_equal(readLines(tmp_down), "viyar fs live test")

  listing <- viya_fs_list(h, paste0(base, "/a"))
  expect_true("hello.txt" %in% listing$name)
  expect_true("b" %in% listing$name)
  # the compute session's own scratch directory is cleaned up by Viya
  # when the session ends -- no explicit cleanup needed here.
})
```

- [ ] **Step 2: Run against the live cluster**

Ask the user which `VIYA_URL` to test against (and confirm a token is
available via `viya_login()` or `VIYA_TOKEN` — do not assume either).
Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS across all unit and live tests, with 0 failures.

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-live-fs.R
git commit -m "Add live tests for folder creation and OS-filesystem access"
```

---

## Task 7: Push the branch

**Files:** none (git operations only).

- [ ] **Step 1: Push**

```bash
git push
```

(The branch already tracks `origin/robustness-auth-and-tests` from
earlier in this PR — a plain `git push` is sufficient, no `-u` needed.)

- [ ] **Step 2: Report back**

Confirm the push succeeded and note that PR #1 now includes this
feature — no new PR needed since this was added to the existing one per
user decision.
