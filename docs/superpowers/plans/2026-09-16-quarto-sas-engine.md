# Quarto `{sas}` Chunk Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Quarto `.qmd` document submit SAS code via a native ` ```{sas} ` fenced chunk, built entirely on `viyar`'s existing `viya_session()`/`viya_submit()` primitives.

**Architecture:** A new knitr custom engine (`sas`), auto-registered when `viyar` loads (if `knitr` is installed), reads a `session` chunk option naming a `viyar` handle the user already created, submits the chunk's code via a new `viya_submit_quarto()` wrapper (fail-fast by default, `output` defaulting to `"html"`), and renders code + log/listing + raw ODS HTML as one `knitr::asis_output()` string.

**Tech Stack:** R, `httr2` (existing), `knitr` (new, optional `Suggests`), `testthat` 3e (mocked unit tests only).

**Spec:** `docs/superpowers/specs/2026-09-16-quarto-sas-engine-design.md`

## Global Constraints

- No change to `viya_submit()` itself — all new behavior lives in the new `viya_submit_quarto()`.
- No automatic session lifecycle — the engine only ever consumes a `viyar` handle the user already created via `viya_session()`; it never starts or ends a session itself.
- `knitr` is a new `Suggests` dependency only, guarded by `requireNamespace()` at every call site that needs it — never a hard `Imports`.
- Chunk options are namespaced `viya.*` (`viya.output`, `viya.error`, `viya.poll_s`, `viya.timeout_s`) — never bare `output`, which collides with knitr/Quarto's own chunk option of that name.
- Default `viya.output` is `"html"` (raw ODS HTML — only renders in HTML-family Quarto targets), not `"log"` like `viya_submit()`'s own default.
- Default behavior is fail-fast: a job state other than `"completed"` raises an R error unless `viya.error: true` is set on that chunk. The job's own `state` field is trusted as-is (no log-content-based override) — this is a deliberate choice, not an oversight (see spec's "Error semantics" section).
- All new tests are mocked-only (`httr2::local_mocked_responses()`), matching the project's existing two-tier unit/live testing convention. No live-cluster test is added for this feature.

---

### Task 1: `viya_submit_quarto()` — the new submit branch

**Files:**
- Create: `R/quarto.R`
- Test: `tests/testthat/test-quarto.R`

**Interfaces:**
- Consumes: `viya_submit(h, code, poll_s, timeout_s, output)` from `R/submit.R` (existing, unmodified); `%||%` from `R/utils.R` (existing).
- Produces: `viya_submit_quarto(h, code, output = "html", poll_s = 1, timeout_s = 300, error = FALSE)`, exported. Returns a list shaped like `viya_submit()`'s own return value (`state`, requested output kinds, `job_id`).

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-quarto.R`:

```r
.quarto_handle <- function() {
  structure(list(token = "t", session = "sess1", context = "ctx",
                 base = "https://viya.example.com"), class = "viyar")
}

# Mirrors .mock_submit() in test-submit.R: dispatches on the request URL,
# with a configurable job `state` for exercising the fail-fast branch.
.mock_quarto_submit <- function(seen, state = "completed", log = list(),
                                listing = NULL, results = NULL, content = NULL) {
  function(req) {
    seen$url <- c(seen$url, req$url)
    u <- req$url
    if (grepl("/jobs$", u))
      return(httr2::response_json(status = 201, body = list(id = "job1")))
    if (grepl("/state$", u))
      return(httr2::response(status = 200, body = charToRaw(state)))
    if (grepl("/log", u))
      return(httr2::response_json(status = 200, body = list(items = log)))
    if (grepl("/listing", u))
      return(httr2::response_json(status = 200, body = list(items = listing %||% list())))
    if (grepl("/results\\?", u))
      return(httr2::response_json(status = 200, body = list(items = results %||% list())))
    if (grepl("/results/", u))
      return(httr2::response(status = 200,
                             body = charToRaw(content[[sub(".*/results/", "", u)]])))
    stop("unexpected request: ", u)
  }
}

test_that("viya_submit_quarto() returns html output and drops the log when the job completes", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    results = list(list(id = "r1", name = "Print", type = "ODS", links = list(
      list(rel = "content",
           href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  r <- viya_submit_quarto(h, "ods html5; proc print data=sashelp.class; run;")

  expect_equal(r$state, "completed")
  expect_equal(unname(r$html), "<html>Alfred</html>")
  expect_null(r$log)
})

test_that("viya_submit_quarto() throws on a non-completed state, with the log tail in the message", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "error",
    log = list(list(line = "NOTE: start"), list(line = "ERROR: bad syntax"))))

  expect_error(
    viya_submit_quarto(h, "proc pint data=sashelp.class; run;"),
    "ERROR: bad syntax", fixed = TRUE)
})

test_that("viya_submit_quarto(error = TRUE) suppresses the throw and keeps the log for display", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "error",
    log = list(list(line = "ERROR: bad syntax"))))

  r <- viya_submit_quarto(h, "proc pint data=sashelp.class; run;", error = TRUE)

  expect_equal(r$state, "error")
  expect_equal(r$log, "ERROR: bad syntax")
})

test_that("viya_submit_quarto() keeps every explicitly requested output kind", {
  h <- .quarto_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    listing = list(list(line = "Obs   Name"))))

  r <- viya_submit_quarto(h, "proc print; run;", output = c("log", "listing"))

  expect_equal(r$listing, "Obs   Name")
  expect_equal(r$log, character())
})

test_that("viya_submit_quarto() rejects an unknown output kind", {
  h <- .quarto_handle()
  expect_error(viya_submit_quarto(h, "run;", output = "pdf"), "should be one of")
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: FAIL — `could not find function "viya_submit_quarto"`.

- [ ] **Step 3: Write the implementation**

Create `R/quarto.R`:

```r
#' Submit SAS code inside a Quarto/knitr chunk, failing fast on error
#'
#' The engine-facing counterpart to [viya_submit()]: same submit-and-poll
#' behavior, but tuned for a rendered document rather than an interactive
#' call. The log is always fetched internally (regardless of `output`) so
#' a failure can be diagnosed from the error message alone; it is dropped
#' from the returned list again unless `"log"` was one of the kinds you
#' asked for, or the job didn't complete.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param code SAS code as a single string (newlines allowed).
#' @param output Which output kinds to retrieve: any of `"log"`,
#'   `"listing"`, `"html"`. Defaults to `"html"` -- unlike [viya_submit()]
#'   itself (which defaults to `"log"`), since this function is meant for
#'   rendering a report-style document, not console debugging.
#' @param poll_s Polling interval in seconds.
#' @param timeout_s Give up after this many seconds.
#' @param error If `FALSE` (the default), a job state other than
#'   `"completed"` raises an R error (including the last few log lines),
#'   stopping the render. Set `TRUE` to suppress the error and return the
#'   result as-is instead, e.g. for a chunk where a non-`"completed"`
#'   state is expected or acceptable.
#' @return A list shaped like [viya_submit()]'s own return value.
#' @examples
#' \dontrun{
#' h <- viya_session()
#' r <- viya_submit_quarto(h, "ods html5; proc means data=sashelp.class; run;")
#' r$html[[1]]
#' }
#' @export
viya_submit_quarto <- function(h, code, output = "html", poll_s = 1,
                               timeout_s = 300, error = FALSE) {
  stopifnot(inherits(h, "viyar"))
  output <- match.arg(output, c("log", "listing", "html"), several.ok = TRUE)
  r <- viya_submit(h, code, poll_s = poll_s, timeout_s = timeout_s,
                   output = union(output, "log"))
  failed <- !identical(r$state, "completed")
  if (failed && !error) {
    tail_lines <- utils::tail(r$log, 5)
    stop("SAS job did not complete (state: \"", r$state, "\")",
         if (length(tail_lines)) paste0(":\n", paste(tail_lines, collapse = "\n")) else "",
         call. = FALSE)
  }
  if (!("log" %in% output) && !failed) r$log <- NULL
  r
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: PASS (5 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/quarto.R tests/testthat/test-quarto.R
git commit -m "$(cat <<'EOF'
Add viya_submit_quarto(): a fail-fast submit wrapper for rendered docs

Same submit-and-poll behavior as viya_submit(), but defaults output to
"html" and raises an R error on a non-completed job state unless
error = TRUE -- the semantics the upcoming {sas} knitr engine needs.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Engine internals — session resolution and output rendering

**Files:**
- Modify: `R/quarto.R` (append)
- Modify: `DESCRIPTION` (add `knitr` to `Suggests`)
- Modify: `tests/testthat/test-quarto.R` (append)

**Interfaces:**
- Consumes: `viya_submit_quarto()` from Task 1.
- Produces (all internal, not exported): `.viya_resolve_session(session)`, `.viya_sas_render(options, code, result)`, `.viya_sas_engine(options)` — the knitr engine callback, taking knitr's own chunk-options list (`options$code`, `options$session`, `options$echo`, `options$viya.output`, `options$viya.error`, `options$viya.poll_s`, `options$viya.timeout_s`) and returning a `knitr::asis_output()` string.

- [ ] **Step 1: Add `knitr` to `DESCRIPTION`'s `Suggests`**

In `DESCRIPTION`, change:

```
Suggests:
    rstudioapi,
    connectapi,
    testthat (>= 3.0.0),
    pkgload,
    withr
```

to:

```
Suggests:
    rstudioapi,
    connectapi,
    knitr,
    testthat (>= 3.0.0),
    pkgload,
    withr
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/testthat/test-quarto.R`:

```r
test_that(".viya_resolve_session() looks up a string option as a variable name in the global env", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("test_quarto_handle", h, envir = .GlobalEnv)
  withr::defer(rm("test_quarto_handle", envir = .GlobalEnv))

  expect_identical(.viya_resolve_session("test_quarto_handle"), h)
})

test_that(".viya_resolve_session() accepts an already-resolved handle object", {
  h <- .quarto_handle()
  expect_identical(.viya_resolve_session(h), h)
})

test_that(".viya_resolve_session() errors clearly with no session option", {
  expect_error(.viya_resolve_session(NULL), "requires a `session`")
})

test_that(".viya_resolve_session() errors clearly when the name isn't a viyar handle", {
  skip_if_not_installed("knitr")
  assign("test_not_a_handle", list(x = 1), envir = .GlobalEnv)
  withr::defer(rm("test_not_a_handle", envir = .GlobalEnv))

  expect_error(.viya_resolve_session("test_not_a_handle"),
              "does not resolve to a viyar handle")
})

test_that(".viya_sas_render() echoes the code and shows the log as a fenced block by default", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = TRUE), "proc means; run;",
                          list(state = "completed", log = c("NOTE: done")))

  expect_s3_class(out, "knit_asis")
  expect_true(grepl("```sas\nproc means; run;\n```", out, fixed = TRUE))
  expect_true(grepl("NOTE: done", out, fixed = TRUE))
})

test_that(".viya_sas_render() omits the code block when echo is FALSE", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "proc means; run;",
                          list(state = "completed", log = c("NOTE: done")))

  expect_false(grepl("proc means; run;", out, fixed = TRUE))
})

test_that(".viya_sas_render() emits html output raw, without fencing", {
  skip_if_not_installed("knitr")
  out <- .viya_sas_render(list(echo = FALSE), "ods html5; proc means; run;",
                          list(state = "completed", html = c(Print = "<p>hi</p>")))

  expect_true(grepl("<p>hi</p>", out, fixed = TRUE))
  expect_false(grepl("```", out, fixed = TRUE))
})

test_that(".viya_sas_engine() resolves the session, submits the code, and renders html output", {
  skip_if_not_installed("knitr")
  h <- .quarto_handle()
  assign("engine_test_handle", h, envir = .GlobalEnv)
  withr::defer(rm("engine_test_handle", envir = .GlobalEnv))

  seen <- new.env()
  httr2::local_mocked_responses(.mock_quarto_submit(
    seen, state = "completed",
    results = list(list(id = "r1", name = "Print", type = "ODS", links = list(
      list(rel = "content",
           href = "/compute/sessions/sess1/jobs/job1/results/r1/content")))),
    content = list("r1/content" = "<html>Alfred</html>")))

  options <- list(session = "engine_test_handle",
                  code = c("ods html5;", "proc print data=sashelp.class; run;"),
                  echo = TRUE, viya.output = "html")

  out <- .viya_sas_engine(options)

  expect_true(grepl("<html>Alfred</html>", out, fixed = TRUE))
  expect_true(grepl("```sas", out, fixed = TRUE))
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: FAIL — `could not find function ".viya_resolve_session"` (and similarly for `.viya_sas_render`/`.viya_sas_engine`).

- [ ] **Step 4: Write the implementation**

Append to `R/quarto.R`:

```r
# Mirrors knitr's own eng_sql(): a chunk option given as a bare name (the
# only form YAML `#|` chunk-option syntax allows without `!expr`) is
# looked up as a variable in the knit environment; classic `{sas,
# session=h}` header syntax evaluates `h` itself before the engine ever
# sees it, so an already-resolved handle is accepted as-is too.
.viya_resolve_session <- function(session) {
  if (is.null(session))
    stop("The `sas` engine requires a `session` chunk option naming (or ",
         "providing) a viyar handle, e.g. `#| session: h` (see viya_session()).",
         call. = FALSE)
  h <- if (is.character(session) && length(session) == 1L)
    get(session, envir = knitr::knit_global())
  else session
  if (!inherits(h, "viyar"))
    stop("`session` does not resolve to a viyar handle (see viya_session()).",
         call. = FALSE)
  h
}

# Builds the whole chunk output (code echo + log/listing + raw ODS html)
# as one markdown/HTML string, returned via knitr::asis_output() so it is
# spliced in verbatim regardless of the chunk's own `results` option --
# the formatting decisions here (fencing, raw HTML) are made once, by
# this function, not deferred to knitr's own results-handling rules.
.viya_sas_render <- function(options, code, result) {
  parts <- character(0)
  if (!identical(options$echo, FALSE))
    parts <- c(parts, paste0("```sas\n", code, "\n```"))
  if (!is.null(result$log) && length(result$log))
    parts <- c(parts, paste0("```\n", paste(result$log, collapse = "\n"), "\n```"))
  if (!is.null(result$listing) && length(result$listing))
    parts <- c(parts, paste0("```\n", paste(result$listing, collapse = "\n"), "\n```"))
  if (!is.null(result$html) && length(result$html))
    parts <- c(parts, unname(result$html))
  knitr::asis_output(paste(parts, collapse = "\n\n"))
}

# The knit_engines$set(sas = ...) callback (registered in R/zzz.R). Takes
# the full chunk options list (knitr's own contract for custom engines --
# code lives at options$code, one element per source line) and returns
# the rendered chunk output.
.viya_sas_engine <- function(options) {
  h <- .viya_resolve_session(options$session)
  code <- paste(options$code, collapse = "\n")
  result <- viya_submit_quarto(
    h, code,
    output = options$viya.output %||% "html",
    poll_s = options$viya.poll_s %||% 1,
    timeout_s = options$viya.timeout_s %||% 300,
    error = isTRUE(options$viya.error))
  .viya_sas_render(options, code, result)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: PASS (13 tests, 0 failures) — or all non-`knitr` tests pass and the rest skip, if `knitr` isn't installed locally.

- [ ] **Step 6: Commit**

```bash
git add R/quarto.R DESCRIPTION tests/testthat/test-quarto.R
git commit -m "$(cat <<'EOF'
Add the sas knitr engine's session-resolution and rendering internals

.viya_resolve_session() mirrors knitr's own eng_sql() name-lookup
convention; .viya_sas_render() assembles code echo + log/listing + raw
ODS HTML into one asis_output() string; .viya_sas_engine() wires both
together as the engine callback knit_engines$set() will register.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Register the engine on package load

**Files:**
- Create: `R/zzz.R`
- Modify: `tests/testthat/test-quarto.R` (append)
- Regenerate: `NAMESPACE`, `man/viya_submit_quarto.Rd` (via `roxygen2::roxygenise()`)

**Interfaces:**
- Consumes: `.viya_sas_engine` from Task 2.
- Produces: `.onLoad(libname, pkgname)` in `R/zzz.R`. After this task, `viya_submit_quarto()` is exported (`NAMESPACE` gains `export(viya_submit_quarto)`) and documented (`man/viya_submit_quarto.Rd` exists) — until this task runs, it's only reachable via `pkgload::load_all()`, not `library(viyar)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/testthat/test-quarto.R`:

```r
test_that("the sas knitr engine is registered when the package loads and knitr is available", {
  skip_if_not_installed("knitr")
  expect_true(is.function(knitr::knit_engines$get("sas")))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: FAIL — `is.function(knitr::knit_engines$get("sas"))` is not `TRUE` (nothing has registered the engine yet).

- [ ] **Step 3: Write the implementation**

Create `R/zzz.R`:

```r
.onLoad <- function(libname, pkgname) {
  if (requireNamespace("knitr", quietly = TRUE)) {
    knitr::knit_engines$set(sas = .viya_sas_engine)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-quarto.R")'`
Expected: PASS (14 tests, 0 failures).

- [ ] **Step 5: Regenerate NAMESPACE and man pages**

Run: `Rscript -e 'roxygen2::roxygenise()'`
Expected: `NAMESPACE` gains a new line, `export(viya_submit_quarto)`, inserted alphabetically; `man/viya_submit_quarto.Rd` is created from Task 1's roxygen comment block.

Verify: `grep viya_submit_quarto NAMESPACE` prints `export(viya_submit_quarto)`.

- [ ] **Step 6: Run the full test suite to confirm nothing else broke**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS, 0 failures, across every `test-*.R` file (excluding the `test-live-*.R` files, which auto-skip with no Viya URL/token configured).

- [ ] **Step 7: Commit**

```bash
git add R/zzz.R NAMESPACE man/viya_submit_quarto.Rd tests/testthat/test-quarto.R
git commit -m "$(cat <<'EOF'
Register the sas knitr engine on package load

library(viyar) is now enough for a Quarto {sas} chunk to work, as long
as knitr is installed -- no separate registration call needed.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Documentation — dedicated example and `CLAUDE.md`

**Files:**
- Create: `examples/viyar-quarto-sas.qmd`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the working `{sas}` engine and `viya_submit_quarto()` from Tasks 1–3 (for accurate example code — no new R code in this task).
- Produces: nothing consumed by later tasks; this is the last task in the plan.

- [ ] **Step 1: Create the dedicated example**

Create `examples/viyar-quarto-sas.qmd`:

````markdown
---
title: "viyar: the {sas} Quarto chunk engine"
subtitle: "Submitting SAS code from a Quarto document"
format:
  html:
    toc: true
    toc-depth: 2
    embed-resources: true
editor: visual
---

## What this notebook shows

`viyar` registers a knitr chunk engine named `sas` when the package
loads (as long as `knitr` is installed). Any ```{sas}``` block in a
Quarto document is then submitted to a Viya compute session you've
already started -- the engine never starts or ends a session itself,
matching how R chunks share one implicit R process throughout a
document.

## Setup

Start the session exactly as you would for any other `viyar` workflow --
see `viyar-workflow-demo.qmd` for the full authentication walkthrough
(Workbench managed OAuth vs. `viya_login()` for local desktop R/Positron
Desktop). Nothing about authentication changes for the `{sas}` engine.

```{r}
#| label: setup
#| eval: false

library(viyar)
h <- viya_session()
```

## A basic `{sas}` chunk

By default, `viya.output` is `"html"` -- your SAS code's own `ods html5`
output (opened with no `file=`, per `viya_submit()`'s existing
convention) is rendered directly into the document, with no log shown.
This is deliberately a clean-report default, not a debugging default.

```{sas}
#| session: h
#| eval: false

ods html5;
proc means data=sashelp.class;
run;
ods html5 close;
```

## Showing the log or the traditional listing instead

Set `viya.output` to any combination of `"log"`, `"listing"`, `"html"`.
`viya.output: "listing"` is also the documented alternative for
non-HTML Quarto targets (PDF/Typst/docx), where raw ODS HTML can't
render.

```{sas}
#| session: h
#| viya.output: ["log", "listing"]
#| eval: false

ods listing;
proc print data=sashelp.class(obs=5);
run;
ods listing close;
```

## Hiding the SAS source

Standard knitr `echo` applies -- set it to `false` to hide the
submitted code and show only the requested output.

```{sas}
#| session: h
#| echo: false
#| eval: false

proc means data=sashelp.class;
run;
```

## A chunk where a non-`"completed"` state is expected

By default, any job state other than `"completed"` stops the render
(fail-fast) -- appropriate for a submission pipeline, where an
unnoticed downstream error is worse than a stopped build. Set
`viya.error: true` to suppress that for a specific chunk instead.

```{sas}
#| session: h
#| viya.error: true
#| eval: false

%put NOTE: this chunk demonstrates viya.error, not a real failure;
```

## Chunk option reference

| Option | Default | Meaning |
|---|---|---|
| `session` | *(required)* | R symbol naming the `viyar` handle, e.g. `h` |
| `viya.output` | `"html"` | one or more of `"log"`, `"listing"`, `"html"` |
| `viya.error` | `false` | suppress the fail-fast throw for this chunk |
| `echo` | `true` | show the submitted SAS source (standard knitr option) |
| `viya.poll_s` | `1` | polling interval in seconds |
| `viya.timeout_s` | `300` | give up after this many seconds |

## Clean up

```{r}
#| label: cleanup
#| eval: false

viya_end(h)
```
````

- [ ] **Step 2: Add a `CLAUDE.md` architecture entry**

In `CLAUDE.md`, in the `## Architecture` list, after the `R/fs.R` bullet (the last existing bullet in that list) and before the closing of the list, add:

```markdown
- `R/quarto.R` — a knitr chunk engine (`{sas}`) for Quarto documents:
  `viya_submit_quarto()` (submit-and-poll like `viya_submit()`, but
  always fetches the log internally for diagnosis, defaults `output` to
  `"html"` instead of `"log"`, and raises an R error on any
  non-`"completed"` job state unless `error = TRUE`) and the engine
  internals it's built on -- `.viya_resolve_session()` (a chunk's
  `session` option, resolved the same way knitr's own `sql` engine
  resolves `connection`: a bare name is looked up in
  `knitr::knit_global()`, an already-resolved handle is passed through
  as-is) and `.viya_sas_render()` (assembles code echo + log/listing
  fenced blocks + raw ODS HTML into one `knitr::asis_output()` string,
  bypassing the chunk's own `results` option entirely since formatting
  is fully decided here). The compute session itself is never started
  or ended automatically -- a document's setup chunk calls
  `viya_session()`/`viya_end()` exactly as it does today; the engine
  only ever consumes a handle the user already made. Chunk options are
  namespaced `viya.*` (`viya.output`, `viya.error`, `viya.poll_s`,
  `viya.timeout_s`) to avoid colliding with knitr/Quarto's own `output`
  chunk option. See
  `docs/superpowers/specs/2026-09-16-quarto-sas-engine-design.md` for
  the full design rationale, including why the sticky session-wide
  error state (see "Known gaps / follow-ups" below) is neutralized
  rather than worked around by this engine's fail-fast default.
- `R/zzz.R` — `.onLoad()` registers the `sas` engine
  (`knitr::knit_engines$set(sas = .viya_sas_engine)`) only if `knitr`
  is installed (a `Suggests`, not a hard dependency).
```

- [ ] **Step 3: Commit**

```bash
git add examples/viyar-quarto-sas.qmd CLAUDE.md
git commit -m "$(cat <<'EOF'
Document the {sas} Quarto chunk engine

Adds a dedicated example .qmd (kept separate from the general workflow
demo) and a CLAUDE.md architecture entry for R/quarto.R and R/zzz.R.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
