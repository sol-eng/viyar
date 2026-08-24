# viyar Robustness, SSO Auth, and Test Suite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive browser-SSO login (`viya_login()`) so the
package can be used and tested from a plain desktop R session, harden the
existing REST call path (errors, retries, input validation, a TLS bug),
and build a two-tier testthat suite (mocked unit tests + live tests
against a real Viya cluster) so future changes have a real regression
safety net.

**Architecture:** All hardening flows through the single internal request
builder `.viya_req()` in `R/utils.R`, so every exported function benefits
automatically. SSO login lives in a new `R/login.R` and only ever *feeds*
the existing token cache in `R/auth.R` — it does not replace the
Workbench or `VIYA_TOKEN` paths, it's added as another rung on the same
ladder. Tests are two tiers: `httr2::local_mocked_responses()` /
`testthat::local_mocked_bindings()` for fast offline unit tests, and a
separate `test-live-*.R` set gated by a skip helper for real-cluster runs.

**Tech Stack:** R (>= 4.1.0), httr2, openssl (PKCE + JWT decoding),
jsonlite (JSON parsing — already an undeclared transitive runtime
dependency via `httr2::resp_body_json()`, being declared explicitly here),
testthat (>= 3.0.0, edition 3), rstudioapi (Suggests, unchanged), roxygen2
for docs/NAMESPACE generation.

**Spec:** `docs/superpowers/specs/2026-08-24-robustness-auth-testing-design.md`

## Global Constraints

- Test cluster for all live testing: `https://viya.pcluster.soleng.posit.it`.
- OAuth client id for SSO: `vscode-positron`.
- No CI wiring in this PR — both test tiers run locally via
  `pkgload::load_all("."); testthat::test_dir("tests/testthat")` (`pkgload`
  loads the uninstalled package's full namespace, including unexported
  `.foo()` helpers, into the session first — plain `test_dir()` alone
  cannot see them; no `devtools` dependency needed, `pkgload` is enough).
- Follow existing code style exactly: base-pipe (`|>`), `httr2::` /
  `utils::` fully-qualified calls (no library() calls in R/ files),
  `message()` for user-facing progress, `stopifnot()` for input
  validation, roxygen2 doc blocks on every exported function.
- Every new/changed exported function gets a roxygen2 doc block; run
  `roxygen2::roxygenise()` (installed locally, matches
  `Config/roxygen2/version: 8.1.0` in `DESCRIPTION`) to regenerate
  `NAMESPACE`/`man/*.Rd` — never hand-edit those generated files.
- `jsonlite` and `openssl` verified already installed and are hard
  dependencies of `httr2` itself (`openssl`) or required at runtime by
  `httr2::resp_body_json()` (`jsonlite`) — adding them to `Imports` is a
  correctness fix, not a new supply-chain risk.
- Package root for all file paths below: `viyar/` (repo root, i.e. the
  git repository containing `DESCRIPTION`).

---

## Task 1: Harden `.viya_req()` and fix `viya_reachable()`'s TLS bug, set up testthat

**Files:**
- Modify: `DESCRIPTION`
- Create: `tests/testthat.R`
- Create: `tests/testthat/test-utils.R`
- Modify: `R/utils.R` (all of it — 29 lines today)

**Interfaces:**
- Produces: `.viya_is_transient(resp)` (httr2_response -> logical),
  `.viya_error_body(resp)` (httr2_response -> character or NULL, used as
  the `body` callback of `httr2::req_error()`), `.viya_req(h, path)`
  (unchanged signature: list with `$token`/`$base`, character path ->
  httr2_request, now with retry + error-body parsing attached),
  `viya_reachable(url, timeout_s, insecure = FALSE)` (new `insecure` arg,
  default now verifies TLS).

- [ ] **Step 1: Add test dependencies to `DESCRIPTION`**

Edit `DESCRIPTION`'s `Imports:` and `Suggests:` blocks to:

```
Imports:
    httr2 (>= 1.0.0),
    curl,
    jsonlite,
    openssl,
    utils,
    stats
Suggests:
    rstudioapi,
    connectapi,
    testthat (>= 3.0.0),
    pkgload
Config/roxygen2/version: 8.1.0
Config/testthat/edition: 3
```

`pkgload` is declared because the local dev-loop test command below
depends on it directly (`pkgload::load_all(".")` loads the uninstalled
package's full namespace — including unexported `.foo()` helpers — before
`testthat::test_dir()` runs; plain `test_dir()` alone cannot see them). It
was already installed transitively as a `testthat` build dependency.

- [ ] **Step 2: Create the testthat entry point**

Create `tests/testthat.R`:

```r
library(testthat)
library(viyar)

test_check("viyar")
```

- [ ] **Step 3: Write the failing tests**

Create `tests/testthat/test-utils.R`:

```r
test_that(".viya_is_transient flags retryable statuses only", {
  expect_true(.viya_is_transient(httr2::response(status = 429)))
  expect_true(.viya_is_transient(httr2::response(status = 500)))
  expect_true(.viya_is_transient(httr2::response(status = 502)))
  expect_true(.viya_is_transient(httr2::response(status = 503)))
  expect_true(.viya_is_transient(httr2::response(status = 504)))
  expect_false(.viya_is_transient(httr2::response(status = 200)))
  expect_false(.viya_is_transient(httr2::response(status = 404)))
})

test_that(".viya_req wires a 3-try retry policy", {
  req <- .viya_req(list(token = "t", base = "https://viya.example.com"), "/x")
  expect_equal(req$policies$retry_max_tries, 3)
})

test_that(".viya_req surfaces Viya's JSON error message and remediation", {
  resp <- httr2::response_json(
    status = 404,
    body = list(message = "Context 'Bogus' not found.",
                remediation = "Call viya_contexts() to list valid names."))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/compute/contexts/bogus") |> httr2::req_perform(),
                  error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "Context 'Bogus' not found", fixed = TRUE)
  expect_match(conditionMessage(err), "Call viya_contexts", fixed = TRUE)
})

test_that(".viya_req falls back to the default httr2 message for non-JSON errors", {
  resp <- httr2::response(status = 500, body = charToRaw("upstream blew up"))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/x") |> httr2::req_perform(), error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "HTTP 500")
})

test_that(".viya_req surfaces the error message for a vendor +json content type", {
  # SAS Viya REST services commonly return application/vnd.sas.error+json
  # rather than bare application/json.
  resp <- httr2::response(
    status = 400,
    headers = list("Content-Type" = "application/vnd.sas.error+json"),
    body = charToRaw(as.character(jsonlite::toJSON(
      list(message = "Invalid caslib name.", remediation = "Use viya_caslib_tables() to list valid names."),
      auto_unbox = TRUE))))
  httr2::local_mocked_responses(list(resp))
  h <- list(token = "t", base = "https://viya.example.com")
  err <- tryCatch(.viya_req(h, "/x") |> httr2::req_perform(), error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "Invalid caslib name", fixed = TRUE)
  expect_match(conditionMessage(err), "Use viya_caslib_tables", fixed = TRUE)
})

test_that("viya_reachable() verifies TLS by default", {
  expect_false(isTRUE(formals(viya_reachable)$insecure))
})

test_that("viya_reachable() returns FALSE for an unreachable host", {
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1))
  expect_false(viya_reachable("http://127.0.0.1:1", timeout_s = 1, insecure = TRUE))
})
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'` from the package
root.
Expected: FAIL — `.viya_is_transient`, `.viya_error_body` not found, and
`viya_reachable` still hard-codes TLS verification off.

- [ ] **Step 5: Rewrite `R/utils.R`**

Replace the full contents of `R/utils.R` with:

```r
`%||%` <- function(a, b) if (is.null(a)) b else a

.viya_is_transient <- function(resp) {
  httr2::resp_status(resp) %in% c(429, 500, 502, 503, 504)
}

.viya_error_body <- function(resp) {
  body <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
  if (is.null(body)) return(NULL)
  msg <- body$message %||% body$error_description %||% body$error %||% NULL
  rem <- body$remediation %||% NULL
  paste(c(msg, rem), collapse = " ")
}

.viya_req <- function(h, path) {
  httr2::request(paste0(h$base, path)) |>
    httr2::req_auth_bearer_token(h$token) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3, is_transient = .viya_is_transient) |>
    httr2::req_error(body = .viya_error_body)
}

#' Check whether the Viya server is reachable
#'
#' Fast TCP/HTTP probe used to gate connection attempts on unstable networks.
#' Any HTTP response (including 401) counts as reachable.
#'
#' @param url Viya base URL. Defaults to the configured URL
#'   (see [viya_config()]).
#' @param timeout_s Probe timeout in seconds.
#' @param insecure Skip TLS certificate/host verification. Only set this
#'   for a cluster with a self-signed certificate you already trust —
#'   the default verifies TLS.
#' @return `TRUE` if the server answered, `FALSE` otherwise.
#' @examples
#' \dontrun{
#' viya_reachable()
#' }
#' @export
viya_reachable <- function(url = viya_config()$url, timeout_s = 5,
                           insecure = FALSE) {
  tryCatch({
    hd <- curl::new_handle(timeout = timeout_s, connecttimeout = timeout_s,
                           ssl_verifypeer = !insecure, ssl_verifyhost = !insecure)
    curl::curl_fetch_memory(url, handle = hd); TRUE
  }, error = function(e) FALSE)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (7 tests, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add DESCRIPTION tests/testthat.R tests/testthat/test-utils.R R/utils.R
git commit -m "Harden .viya_req() error/retry handling and fix TLS bug in viya_reachable()"
```

---

## Task 2: JWT expiry decoding helper

**Files:**
- Modify: `R/utils.R` (append)
- Modify: `tests/testthat/test-utils.R` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `.jwt_exp(token)` (character JWT -> POSIXct expiry, or
  `as.POSIXct(NA)` if the token isn't a parseable JWT). Used by Task 6/7.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-utils.R`:

```r
mk_jwt <- function(exp) {
  payload <- as.character(jsonlite::toJSON(list(exp = exp), auto_unbox = TRUE))
  seg <- openssl::base64_encode(charToRaw(payload))
  seg <- chartr("+/", "-_", sub("=+$", "", seg))
  paste("header", seg, "sig", sep = ".")
}

test_that(".jwt_exp decodes the exp claim from a base64url JWT payload", {
  target <- as.POSIXct(1893456003, origin = "1970-01-01", tz = "UTC")
  decoded <- .jwt_exp(mk_jwt(1893456003))
  expect_equal(as.numeric(decoded), as.numeric(target))
})

test_that(".jwt_exp returns NA for a non-JWT or malformed token", {
  expect_true(is.na(.jwt_exp("not-a-jwt")))
  expect_true(is.na(.jwt_exp("")))
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.jwt_exp` not found.

- [ ] **Step 3: Implement**

Append to `R/utils.R`:

```r
#' Decode a JWT's `exp` claim
#'
#' Used to know when a cached access token expires ahead of time, rather
#' than discovering it via a 401 mid-workflow.
#'
#' @param token A JWT access token (or any string — non-JWTs return `NA`).
#' @return A POSIXct expiry time, or `NA` if `token` isn't a parseable
#'   JWT with an `exp` claim.
.jwt_exp <- function(token) {
  parts <- strsplit(token, ".", fixed = TRUE)[[1]]
  if (length(parts) < 2) return(as.POSIXct(NA))
  b64 <- chartr("-_", "+/", parts[2])
  b64 <- paste0(b64, strrep("=", (4 - nchar(b64) %% 4) %% 4))
  payload <- tryCatch(
    jsonlite::fromJSON(rawToChar(openssl::base64_decode(b64))),
    error = function(e) NULL)
  if (is.null(payload$exp)) return(as.POSIXct(NA))
  as.POSIXct(payload$exp, origin = "1970-01-01", tz = "UTC")
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (9 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/utils.R tests/testthat/test-utils.R
git commit -m "Add JWT exp-claim decoding helper for proactive token refresh"
```

---

## Task 3: PKCE helpers

**Files:**
- Create: `R/login.R`
- Create: `tests/testthat/test-login.R`

**Interfaces:**
- Produces: `.pkce_verifier()` (-> character, 43-char base64url string from
  32 CSPRNG-generated bytes — RFC 7636's own recommended construction),
  `.pkce_challenge(verifier)` (character -> character, S256
  base64url-encoded SHA256 of `verifier`). Used by Task 6.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-login.R`:

```r
test_that(".pkce_challenge matches the RFC 7636 Appendix B test vector", {
  verifier <- "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  expect_equal(.pkce_challenge(verifier),
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
})

test_that(".pkce_verifier generates a spec-compliant random verifier", {
  v <- .pkce_verifier()
  expect_true(nchar(v) >= 43 && nchar(v) <= 128)
  expect_match(v, "^[A-Za-z0-9._~-]+$")
  expect_false(identical(.pkce_verifier(), .pkce_verifier()))
})
```

Note on the regex: the hyphen is placed last inside the bracket
expression (`._~-`) — R's default (non-Perl/TRE) regex engine parses a
hyphen anywhere else inside `[...]` as a range operator and errors with
"Invalid character range", so `._~-` (or `-._~` with the hyphen first) is
the only safe placement, not `A-Za-z0-9-._~`.

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.pkce_challenge`/`.pkce_verifier` not found.

- [ ] **Step 3: Implement**

Create `R/login.R` with:

```r
.pkce_verifier <- function() {
  raw <- openssl::rand_bytes(32)
  b64 <- openssl::base64_encode(raw)
  chartr("+/", "-_", sub("=+$", "", b64))
}

.pkce_challenge <- function(verifier) {
  digest <- openssl::sha256(charToRaw(verifier))
  b64 <- openssl::base64_encode(digest)
  chartr("+/", "-_", sub("=+$", "", b64))
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (11 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/login.R tests/testthat/test-login.R
git commit -m "Add PKCE verifier/challenge helpers for SSO login"
```

---

## Task 4: Authorization-code / redirect-URL parsing

**Files:**
- Modify: `R/login.R` (append)
- Modify: `tests/testthat/test-login.R` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `.parse_auth_code(input)` (character -> character
  authorization code, or throws a descriptive error). Used by Task 6.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-login.R`:

```r
test_that(".parse_auth_code accepts a bare code", {
  expect_equal(.parse_auth_code("  abc123  "), "abc123")
})

test_that(".parse_auth_code extracts code= from a full redirect URL", {
  expect_equal(
    .parse_auth_code("https://example.com/cb?code=abc123&state=xyz"),
    "abc123")
  expect_equal(
    .parse_auth_code("https://example.com/cb?state=xyz&code=a%2Fb%3Dc"),
    "a/b=c")
})

test_that(".parse_auth_code surfaces an OAuth error param clearly", {
  expect_error(
    .parse_auth_code(paste0("https://example.com/cb?error=access_denied",
                            "&error_description=User%20cancelled")),
    "User cancelled")
})

test_that(".parse_auth_code errors when no code is present", {
  expect_error(.parse_auth_code("https://example.com/cb?state=xyz"),
               "No code parameter")
  expect_error(.parse_auth_code(""), "No authorization code")
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.parse_auth_code` not found.

- [ ] **Step 3: Implement**

Append to `R/login.R`:

```r
.parse_auth_code <- function(input) {
  input <- trimws(input)
  if (!nzchar(input)) stop("No authorization code provided.")
  if (!grepl("^https?://", input)) return(input)

  query <- sub("^[^?]*\\?", "", sub("#.*$", "", input))
  pairs <- strsplit(query, "&", fixed = TRUE)[[1]]
  kv <- strsplit(pairs, "=", fixed = TRUE)
  keys <- vapply(kv, `[`, "", 1)
  vals <- vapply(kv, function(x) if (length(x) > 1) x[2] else "", "")
  names(vals) <- keys

  err <- unname(vals["error"])
  if (!is.na(err) && nzchar(err))
    stop("Viya login failed: ", utils::URLdecode(
      if (!is.na(vals["error_description"])) unname(vals["error_description"])
      else err))
  code <- unname(vals["code"])
  if (is.na(code) || !nzchar(code))
    stop("No code parameter found in the pasted URL.")
  utils::URLdecode(code)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (15 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/login.R tests/testthat/test-login.R
git commit -m "Parse pasted authorization code or full redirect URL for SSO login"
```

---

## Task 5: Token exchange + cache helpers

**Files:**
- Modify: `R/login.R` (append)
- Modify: `tests/testthat/test-login.R` (append)

**Interfaces:**
- Consumes: `.viya_error_body()` (Task 1), `.jwt_exp()` (Task 2), the
  package's existing `.token_cache` environment (`R/auth.R`).
- Produces: `.viya_token_exchange(url, body)` (character url, named list
  body -> parsed JSON response list with at least `access_token`, throws
  on error), `.viya_cache_token(resp, client_id)` (response list,
  character -> character access token, invisibly; also populates
  `.token_cache$tok`/`$refresh`/`$exp`/`$client_id`). Used by Task 6, 7.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-login.R`:

```r
test_that(".viya_token_exchange posts a form body and returns parsed JSON", {
  seen <- NULL
  resp <- httr2::response_json(status = 200, body = list(
    access_token = "AT", refresh_token = "RT", token_type = "bearer"))
  httr2::local_mocked_responses(function(req) {
    seen <<- req
    resp
  })
  out <- .viya_token_exchange("https://viya.example.com", list(
    grant_type = "authorization_code", client_id = "vscode-positron",
    code = "abc123", code_verifier = "verifier-value"))

  expect_equal(seen$url, "https://viya.example.com/SASLogon/oauth/token")
  expect_equal(as.character(seen$body$data$grant_type), "authorization_code")
  expect_equal(as.character(seen$body$data$code), "abc123")
  expect_equal(out$access_token, "AT")
  expect_equal(out$refresh_token, "RT")
})

test_that(".viya_token_exchange surfaces SASLogon's error_description", {
  resp <- httr2::response_json(status = 400, body = list(
    error = "invalid_grant", error_description = "Invalid authorization code"))
  httr2::local_mocked_responses(list(resp))
  expect_error(
    .viya_token_exchange("https://viya.example.com", list(grant_type = "x")),
    "Invalid authorization code")
})

test_that(".viya_cache_token populates the token cache from a token response", {
  exp_time <- as.numeric(Sys.time()) + 36000
  payload <- as.character(jsonlite::toJSON(list(exp = exp_time), auto_unbox = TRUE))
  seg <- chartr("+/", "-_", sub("=+$", "", openssl::base64_encode(charToRaw(payload))))
  tok <- paste("h", seg, "s", sep = ".")

  out <- .viya_cache_token(list(access_token = tok, refresh_token = "RT"),
                            client_id = "vscode-positron")
  expect_equal(out, tok)
  expect_equal(.token_cache$tok, tok)
  expect_equal(.token_cache$refresh, "RT")
  expect_equal(.token_cache$client_id, "vscode-positron")
  expect_equal(as.numeric(.token_cache$exp), exp_time)
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.viya_token_exchange`/`.viya_cache_token` not found.

- [ ] **Step 3: Implement**

Append to `R/login.R`:

```r
.viya_token_exchange <- function(url, body) {
  httr2::request(paste0(url, "/SASLogon/oauth/token")) |>
    httr2::req_headers(Accept = "application/json") |>
    (\(req) do.call(httr2::req_body_form, c(list(req), body)))() |>
    httr2::req_error(body = .viya_error_body) |>
    httr2::req_perform() |> httr2::resp_body_json()
}

.viya_cache_token <- function(resp, client_id) {
  .token_cache$tok <- resp$access_token
  .token_cache$refresh <- resp$refresh_token
  .token_cache$exp <- .jwt_exp(resp$access_token)
  .token_cache$client_id <- client_id
  invisible(resp$access_token)
}
```

Note: `.token_cache` is defined in `R/auth.R` (`.token_cache <- new.env(parent
= emptyenv())`) — both files are part of the same package namespace, so no
import is needed.

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (18 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/login.R tests/testthat/test-login.R
git commit -m "Add SASLogon token-exchange and token-cache helpers"
```

---

## Task 6: `viya_login()` — the exported SSO entry point

**Files:**
- Modify: `R/login.R` (append)

**Interfaces:**
- Consumes: `.pkce_verifier()`, `.pkce_challenge()` (Task 3),
  `.parse_auth_code()` (Task 4), `.viya_token_exchange()`,
  `.viya_cache_token()` (Task 5), `viya_config()` (`R/auth.R`, unchanged
  signature).
- Produces: `viya_login(url, client_id, redirect_uri, scope)` (exported,
  returns the access token invisibly). Used interactively by the user and
  by `viya_token()` in Task 7 (indirectly, via the token cache it
  populates).

This task's `readline()` call means it can't be exercised by an automated
test — it's validated live in Task 12. No test file changes here.

- [ ] **Step 1: Implement**

Append to `R/login.R`:

```r
#' Log in to Viya interactively via browser SSO
#'
#' For use outside Posit Workbench (e.g. a local desktop R session):
#' opens a Viya login page in your browser using the OAuth authorization
#' code flow with PKCE, then exchanges the code you paste back for an
#' access token. The token (and refresh token, if issued) is cached and
#' picked up automatically by [viya_token()] and [viya_session()] for the
#' rest of the R session, refreshing itself silently as it nears expiry.
#'
#' @param url Viya base URL; defaults to the configured URL (see
#'   [viya_config()]).
#' @param client_id OAuth client id registered on the Viya server for
#'   interactive/CLI logins.
#' @param redirect_uri Optional redirect URI to send in the authorization
#'   request. Leave `NULL` to let the server use its registered default
#'   for `client_id`.
#' @param scope OAuth scopes to request.
#' @return The access token (character scalar), invisibly.
#' @examples
#' \dontrun{
#' viya_login(url = "https://viya.example.com")
#' h <- viya_session()
#' }
#' @export
viya_login <- function(url = viya_config()$url,
                       client_id = "vscode-positron",
                       redirect_uri = NULL,
                       scope = "openid") {
  if (!nzchar(url)) stop("No Viya URL configured. viya_config(url = ...) ",
                         "or set VIYA_URL.")

  verifier  <- .pkce_verifier()
  challenge <- .pkce_challenge(verifier)

  q <- list(client_id = client_id, response_type = "code", scope = scope,
            code_challenge = challenge, code_challenge_method = "S256")
  if (!is.null(redirect_uri)) q$redirect_uri <- redirect_uri
  authorize_url <- do.call(httr2::url_modify_query,
                           c(list(paste0(url, "/SASLogon/oauth/authorize")), q))

  message("Opening Viya login in your browser:\n", authorize_url)
  tryCatch(utils::browseURL(authorize_url), error = function(e) NULL)

  raw <- readline(
    "After logging in, paste the authorization code (or the full redirect URL) here: ")
  code <- .parse_auth_code(raw)

  body <- list(grant_type = "authorization_code", client_id = client_id,
               code = code, code_verifier = verifier)
  if (!is.null(redirect_uri)) body$redirect_uri <- redirect_uri
  resp <- .viya_token_exchange(url, body)
  tok  <- .viya_cache_token(resp, client_id)
  message("Viya login succeeded; token cached",
          if (!is.na(.token_cache$exp))
            paste0(" (expires ", format(.token_cache$exp, usetz = TRUE), ")")
          else "", ".")
  invisible(tok)
}
```

- [ ] **Step 2: Sanity-check it sources cleanly**

Run: `Rscript -e 'source("R/utils.R"); source("R/auth.R"); source("R/login.R"); cat("ok\n")'`
Expected: `ok` with no errors (confirms no syntax errors / missing
symbols at parse time; the interactive flow itself is validated in
Task 12).

- [ ] **Step 3: Commit**

```bash
git add R/login.R
git commit -m "Add viya_login() interactive browser-SSO entry point"
```

---

## Task 7: Extend `viya_token()`'s resolution order

**Files:**
- Modify: `R/auth.R:45-78` (the `viya_token()` function; `viya_config()`
  above it and `.token_cache` on line 43 are untouched by this task)
- Create: `tests/testthat/test-auth.R`

**Interfaces:**
- Consumes: `.jwt_exp()` (Task 2), `.viya_token_exchange()`,
  `.viya_cache_token()` (Task 5), the existing `.token_cache` env and
  `viya_config()`.
- Produces: `viya_token(refresh = FALSE)` — same signature as today, new
  resolution order documented below. Used by every other exported
  function via its `token = viya_token()` default argument (unchanged
  call sites).

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-auth.R`:

```r
mk_jwt <- function(exp) {
  payload <- as.character(jsonlite::toJSON(list(exp = exp), auto_unbox = TRUE))
  seg <- chartr("+/", "-_", sub("=+$", "", openssl::base64_encode(charToRaw(payload))))
  paste("h", seg, "s", sep = ".")
}

reset_token_cache <- function() {
  rm(list = ls(envir = .token_cache), envir = .token_cache)
}

test_that("VIYA_TOKEN env var always wins", {
  withr::local_envvar(VIYA_TOKEN = "env-token")
  expect_equal(viya_token(), "env-token")
})

test_that("a fresh cached token is returned without any network call", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  .token_cache$tok <- "cached-tok"
  .token_cache$exp <- Sys.time() + 3600
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  httr2::local_mocked_responses(function(req) stop("should not hit the network"))
  expect_equal(viya_token(), "cached-tok")
})

test_that("an expired cached token refreshes via the stored refresh_token", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  .token_cache$tok <- mk_jwt(as.numeric(Sys.time()) - 10)
  .token_cache$exp <- .jwt_exp(.token_cache$tok)
  .token_cache$refresh <- "refresh-abc"
  .token_cache$client_id <- "vscode-positron"
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")

  new_access <- mk_jwt(as.numeric(Sys.time()) + 36000)
  resp <- httr2::response_json(status = 200, body = list(
    access_token = new_access, refresh_token = "refresh-def"))
  seen <- NULL
  httr2::local_mocked_responses(function(req) { seen <<- req; resp })

  out <- viya_token()
  expect_equal(out, new_access)
  expect_equal(as.character(seen$body$data$grant_type), "refresh_token")
  expect_equal(as.character(seen$body$data$refresh_token), "refresh-abc")
  expect_equal(.token_cache$refresh, "refresh-def")
})

test_that("Workbench managed OAuth is tried when rstudioapi reports available", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  tok <- mk_jwt(as.numeric(Sys.time()) + 36000)
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(guid = "guid-1"),
    getOAuthCredentials = function(...) list(access_token = tok),
    .package = "rstudioapi")

  expect_equal(viya_token(), tok)
  expect_equal(.token_cache$tok, tok)
})

test_that("a non-Workbench RStudio/Positron session falls through instead of erroring", {
  # isAvailable() is TRUE outside Workbench too (plain RStudio Desktop, a
  # local Positron session); findOAuthIntegration() itself asserts a real
  # Workbench session and throws otherwise -- viya_token() must catch that
  # and fall through to its next resolution step, not propagate the error.
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...)
      stop("assertWorkbenchSession(): only available within Posit Workbench sessions"),
    .package = "rstudioapi")

  expect_error(viya_token(), "viya_login\\(\\)")
})

test_that("a clear error is thrown when nothing is available", {
  withr::local_envvar(VIYA_TOKEN = "")
  reset_token_cache()
  testthat::local_mocked_bindings(isAvailable = function(...) FALSE,
                                  .package = "rstudioapi")
  expect_error(viya_token(), "viya_login\\(\\)")
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — current `viya_token()` doesn't check `rstudioapi::isAvailable()`
first (so the "available FALSE" mocks don't prevent a real
`findOAuthIntegration()` attempt) and has no refresh-token path;
depending on environment this errors rather than reaching the assertions.
Also add `withr` to `Suggests` in `DESCRIPTION` if not already resolvable
(it was installed in Task 1 as a transitive dependency of `testthat`, but
declare it explicitly since the tests call it directly):

```
Suggests:
    rstudioapi,
    connectapi,
    testthat (>= 3.0.0),
    pkgload,
    withr
```

- [ ] **Step 3: Implement**

Replace lines 45-78 of `R/auth.R` (the `viya_token()` roxygen block and
function — everything from `#' Obtain a Viya access token` through the
closing `}`) with:

```r
#' Obtain a Viya access token
#'
#' Resolution order: the `VIYA_TOKEN` environment variable if set; a
#' still-fresh cached token from a previous call; Posit Workbench managed
#' OAuth credentials via `rstudioapi` (interactive Workbench sessions);
#' a cached SSO token from [viya_login()], refreshed silently if it's
#' expired or about to expire. On Posit Connect with viewer OAuth
#' integrations, obtain the token yourself (e.g.
#' `connectapi::get_oauth_credentials()` with the viewer session token) and
#' pass it to [viya_session()] via its `token` argument.
#'
#' @param refresh Force re-acquisition instead of returning a still-fresh
#'   cached token (Viya access tokens typically last around 10 hours).
#' @return An OAuth access token (character scalar).
#' @examples
#' \dontrun{
#' tok <- viya_token()
#' }
#' @export
viya_token <- function(refresh = FALSE) {
  tok <- Sys.getenv("VIYA_TOKEN", unset = "")
  if (nzchar(tok)) return(tok)

  if (!refresh && !is.null(.token_cache$tok) &&
      (is.null(.token_cache$exp) || is.na(.token_cache$exp) ||
       .token_cache$exp > Sys.time() + 60)) {
    return(.token_cache$tok)
  }

  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(rstudioapi::isAvailable())) {
    # isAvailable() is TRUE in any RStudio-family frontend (Desktop,
    # Server, Positron) -- not just Workbench. findOAuthIntegration()
    # itself asserts a genuine Workbench session and throws otherwise, so
    # both calls are wrapped in tryCatch to fall through to the next
    # resolution step (rather than error) on plain RStudio Desktop or a
    # local Positron session with no Workbench attached.
    int <- tryCatch(
      rstudioapi::findOAuthIntegration(name = viya_config()$wb_integration),
      error = function(e) NULL)
    if (!is.null(int)) {
      tok <- tryCatch(
        rstudioapi::getOAuthCredentials(audience = int$guid)$access_token,
        error = function(e) NULL)
      if (!is.null(tok)) {
        .token_cache$tok <- tok
        .token_cache$refresh <- NULL
        .token_cache$exp <- .jwt_exp(tok)
        return(tok)
      }
    }
  }

  if (!is.null(.token_cache$refresh)) {
    resp <- tryCatch(
      .viya_token_exchange(viya_config()$url, list(
        grant_type = "refresh_token",
        client_id = .token_cache$client_id,
        refresh_token = .token_cache$refresh)),
      error = function(e) NULL)
    if (!is.null(resp)) return(.viya_cache_token(resp, .token_cache$client_id))
  }

  stop("No Viya token available. Set VIYA_TOKEN, run inside Posit Workbench ",
       "with a matching OAuth integration, or call viya_login() to ",
       "authenticate interactively.")
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (24 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add DESCRIPTION R/auth.R tests/testthat/test-auth.R
git commit -m "Extend viya_token() with expiry-aware caching and SSO refresh fallback"
```

---

## Task 8: Auto-detect the Viya URL from a Workbench OAuth integration

**Files:**
- Modify: `R/auth.R:1-41` (`viya_config()`)
- Modify: `tests/testthat/test-auth.R` (append) — rename conceptually to
  cover `viya_config()` too, but keep appending to the same file since
  both functions live in `R/auth.R`.

**Interfaces:**
- Consumes: `rstudioapi::isAvailable()`, `rstudioapi::findOAuthIntegration()`
  (mocked in tests). Per `rstudioapi::getOAuthIntegration()`'s documented
  return shape, an integration list has an `issuer` field (and
  `auth_url`/`token_url`) that for a SAS Viya deployment is the
  `.../SASLogon/oauth/...` URL — the Viya base URL is everything before
  `/SASLogon`.
- Produces: `.viya_url_from_integration(int)` (integration list ->
  character base URL, or `NULL`). `viya_config()`'s `url` field now
  auto-populates from this when unconfigured and Workbench is available.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-auth.R`:

```r
test_that(".viya_url_from_integration strips the /SASLogon suffix", {
  expect_equal(
    .viya_url_from_integration(list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token")),
    "https://viya.pcluster.soleng.posit.it")
  expect_equal(
    .viya_url_from_integration(list(
      token_url = "https://viya.example.com/SASLogon/oauth/token")),
    "https://viya.example.com")
  expect_null(.viya_url_from_integration(list()))
})

test_that("viya_config() auto-detects the URL from Workbench when unset", {
  withr::local_envvar(VIYA_URL = "")
  withr::local_options(viyar.url = NULL)
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(
      issuer = "https://viya.pcluster.soleng.posit.it/SASLogon/oauth/token"),
    .package = "rstudioapi")

  expect_equal(viya_config()$url, "https://viya.pcluster.soleng.posit.it")
})

test_that("viya_config() prefers an explicitly configured URL over auto-detection", {
  withr::local_envvar(VIYA_URL = "")
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    findOAuthIntegration = function(...) list(
      issuer = "https://auto-detected.example.com/SASLogon/oauth/token"),
    .package = "rstudioapi")

  viya_config(url = "https://explicit.example.com")
  expect_equal(viya_config()$url, "https://explicit.example.com")
  withr::local_options(viyar.url = NULL)
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — `.viya_url_from_integration` not found; `viya_config()`
has no auto-detection.

- [ ] **Step 3: Implement**

Replace lines 1-41 of `R/auth.R` (from `#' Get or set viyar configuration`
through the closing `}` of `viya_config()`) with:

```r
.viya_url_from_integration <- function(int) {
  src <- int$issuer %||% int$token_url %||% int$auth_url
  if (is.null(src)) return(NULL)
  sub("/SASLogon/.*$", "", src)
}

#' Get or set viyar configuration
#'
#' Configuration is resolved from R options first, then environment
#' variables: `url` (option `viyar.url` / env `VIYA_URL`; if still unset
#' and running inside Posit Workbench, auto-detected from the matching
#' OAuth integration's issuer URL), `context` (option `viyar.context` /
#' env `VIYA_CONTEXT`, default `"SAS Studio compute context"`),
#' `cas_server` (option `viyar.cas_server` / env `VIYA_CAS_SERVER`,
#' default `"cas-shared-default"`), and `wb_integration` (option
#' `viyar.wb_integration` / env `VIYA_WB_INTEGRATION`, a regex matching the
#' Posit Workbench managed-credential integration name, default
#' `"^sas-viya$"`).
#'
#' @param ... Named values to set, e.g.
#'   `viya_config(url = "https://viya.example.com")`.
#' @return The current configuration as a named list (invisibly when
#'   setting values).
#' @examples
#' \dontrun{
#' viya_config(url = "https://viya.example.com")
#' viya_config()
#' }
#' @export
viya_config <- function(...) {
  new <- list(...)
  for (nm in names(new)) options(structure(list(new[[nm]]),
                                           names = paste0("viyar.", nm)))

  wb_integration <- getOption("viyar.wb_integration",
                              Sys.getenv("VIYA_WB_INTEGRATION",
                                         unset = "^sas-viya$"))
  url <- getOption("viyar.url", Sys.getenv("VIYA_URL", unset = ""))
  if (!nzchar(url) && requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(rstudioapi::isAvailable())) {
    int <- tryCatch(rstudioapi::findOAuthIntegration(name = wb_integration),
                    error = function(e) NULL)
    if (!is.null(int)) url <- .viya_url_from_integration(int) %||% ""
  }

  cfg <- list(
    url = sub("/+$", "", url),
    context = getOption("viyar.context",
                        Sys.getenv("VIYA_CONTEXT",
                                   unset = "SAS Studio compute context")),
    cas_server = getOption("viyar.cas_server",
                           Sys.getenv("VIYA_CAS_SERVER",
                                      unset = "cas-shared-default")),
    wb_integration = wb_integration
  )
  if (length(new)) invisible(cfg) else cfg
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (27 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/auth.R tests/testthat/test-auth.R
git commit -m "Auto-detect the Viya URL from a Workbench OAuth integration when unset"
```

---

## Task 9: Input validation across `session.R`, `cas.R`, `submit.R`

**Files:**
- Modify: `R/session.R:11` (`viya_contexts`), `R/session.R:113`
  (`viya_sessions`), `R/session.R:128` (`viya_kill`)
- Modify: `R/cas.R:11` (`viya_caslib_files`), `R/cas.R:30`
  (`viya_caslib_tables`), `R/cas.R:65` (`viya_load_table`), `R/cas.R:94`
  (`viya_unload_table`)
- Modify: `R/submit.R:87` (`viya_members`)
- Create: `tests/testthat/test-validation.R`

**Interfaces:**
- Consumes: nothing new — this only adds `stopifnot()` guards matching
  the pattern already used in `data.R`/`files.R`/`submit.R` (e.g.
  `stopifnot(inherits(h, "viyar"))` in `viya_read()`).
- Produces: no new functions; each modified function now throws
  immediately (before any HTTP call) on a missing/invalid handle or
  empty required string argument.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-validation.R`:

```r
bad_h <- list(token = "t", base = "https://viya.example.com")  # missing class

test_that("token/url-based functions validate their arguments", {
  expect_error(viya_contexts(token = "", url = "https://x"), "token")
  expect_error(viya_contexts(token = "t", url = ""), "url")
  expect_error(viya_sessions(token = "", url = "https://x"))
  expect_error(viya_kill("sess-1", token = "", url = "https://x"))
  expect_error(viya_kill("", token = "t", url = "https://x"))
})

test_that("handle-based CAS functions validate their arguments", {
  expect_error(viya_caslib_files(bad_h, "Public"))
  expect_error(viya_caslib_tables(bad_h, "Public"))
  expect_error(viya_load_table(bad_h, "Public", "orders.sashdat"))
  expect_error(viya_unload_table(bad_h, "Public", "ORDERS"))
})

test_that("viya_members validates its handle", {
  expect_error(viya_members(bad_h, "WORK"))
})
```

- [ ] **Step 2: Run to verify failure**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: FAIL — these functions currently attempt a (mocked-away, so
actually network-erroring) HTTP call instead of raising a validation
error, so the `expect_error()` messages/reasons won't match (some may
happen to error anyway from a failed connection, but not for the reason
under test — e.g. `viya_contexts(token = "", ...)` doesn't check `token`
today). Confirm by reading the failure output rather than assuming.

- [ ] **Step 3: Implement**

In `R/session.R`, add a `stopifnot()` as the first line of each function
body (do not change any other line):

- `viya_contexts` (currently line 11-17): after the `viya_contexts <-
  function(token = viya_token(), url = viya_config()$url) {` line, add:
  `stopifnot(nzchar(token), nzchar(url))`
- `viya_sessions` (currently line 113-119): same signature, add the same
  `stopifnot(nzchar(token), nzchar(url))` as its first line.
- `viya_kill` (currently line 128-133): first line of the body becomes
  `stopifnot(nzchar(session_id), nzchar(token), nzchar(url))`.

In `R/cas.R`, add as the first line of each function body:

- `viya_caslib_files`: `stopifnot(inherits(h, "viyar"), nzchar(caslib))`
- `viya_caslib_tables`: `stopifnot(inherits(h, "viyar"), nzchar(caslib))`
- `viya_load_table`: `stopifnot(inherits(h, "viyar"), nzchar(caslib), nzchar(file))`
- `viya_unload_table`: `stopifnot(inherits(h, "viyar"), nzchar(caslib), nzchar(table))`

In `R/submit.R`, add as the first line of `viya_members`'s body:
`stopifnot(inherits(h, "viyar"), nzchar(libref))`

For example, `viya_contexts` becomes:

```r
viya_contexts <- function(token = viya_token(), url = viya_config()$url) {
  stopifnot(nzchar(token), nzchar(url))
  h <- list(token = token, base = url)
  ctx <- .viya_req(h, "/compute/contexts?limit=100") |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(name = vapply(ctx$items, `[[`, "", "name"),
             id   = vapply(ctx$items, `[[`, "", "id"))
}
```

and `viya_load_table` becomes:

```r
viya_load_table <- function(h, caslib, file,
                            casout = toupper(sub("\\.[^.]+$", "", file)),
                            promote = TRUE, replace = FALSE) {
  stopifnot(inherits(h, "viyar"), nzchar(caslib), nzchar(file))
  opt <- if (replace) "replace" else if (promote) "promote" else ""
  code <- sprintf(paste0(
    "%%macro _viyar_cas; ",
    "%%if %%sysfunc(sessfound(_VIYARC_)) = 0 %%then %%do;\n",
    "  cas _VIYARC_;\n%%end; %%mend; %%_viyar_cas;\n",
    "proc casutil session=_VIYARC_ incaslib=\"%s\" outcaslib=\"%s\";\n",
    "  load casdata=\"%s\" casout=\"%s\" %s;\nquit;"),
    caslib, caslib, file, casout, opt)
  r <- viya_submit(h, code)
  if (!identical(r$state, "completed"))
    warning("load state: ", r$state, " - check r$log")
  message("load ", caslib, "/", file, " -> ", casout,
          if (nzchar(opt)) paste0(" (", opt, ")") else "", ": ", r$state)
  invisible(r)
}
```

(Apply the same one-line insertion pattern to the other five functions —
every other line of each function is unchanged.)

- [ ] **Step 4: Run to verify pass**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS (30 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add R/session.R R/cas.R R/submit.R tests/testthat/test-validation.R
git commit -m "Validate handle/token/url arguments before making requests"
```

---

## Task 10: Regenerate roxygen2 docs and update README

**Files:**
- Modify: `NAMESPACE` (regenerated, not hand-edited)
- Modify/Create: `man/*.Rd` (regenerated, not hand-edited)
- Modify: `README.md`

**Interfaces:**
- Consumes: all roxygen2 doc blocks written in Tasks 1-9.
- Produces: `NAMESPACE` gains `export(viya_login)`; nothing else changes
  functionally.

- [ ] **Step 1: Regenerate**

Run: `Rscript -e 'roxygen2::roxygenise()'` from the package root.
Expected: `NAMESPACE` gains `export(viya_login)` (alphabetically between
`viya_load_table` and `viya_members`); `man/viya_login.Rd` and
`man/viya_reachable.Rd` (updated for the new `insecure` param) are
created/updated; no other functional change.

- [ ] **Step 2: Update `README.md`'s authentication section**

Replace the "## Authenticating to SAS Viya" section (currently):

```markdown
## Authenticating to SAS Viya

- Workbench: managed OAuth credentials via rstudioapi (integration name
  configurable, default `^sas-viya$`).
- Posit Connect: obtain a viewer token with connectapi and pass it:
  `viya_session(token = viewer_token)`.
- Anywhere: set `VIYA_TOKEN`.
```

with:

```markdown
## Authenticating to SAS Viya

- Workbench: managed OAuth credentials via rstudioapi (integration name
  configurable, default `^sas-viya$`). The Viya URL is auto-detected from
  the integration if `viya_config(url = ...)`/`VIYA_URL` isn't set.
- Local desktop R (outside Workbench): `viya_login()` opens a browser SSO
  login (authorization code + PKCE) and caches the resulting token,
  refreshing it automatically as it nears expiry.
- Posit Connect: obtain a viewer token with connectapi and pass it:
  `viya_session(token = viewer_token)`.
- Anywhere: set `VIYA_TOKEN`.
```

- [ ] **Step 3: Verify the package still loads cleanly**

Run: `Rscript -e 'pkgload::load_all("."); cat("loaded ok\n")'` (installs
`pkgload` if not already present via `install.packages("pkgload")` — it
was already pulled in as a `testthat` dependency in Task 1).
Expected: `loaded ok` with no errors, confirming the roxygen2 regen
didn't break anything.

- [ ] **Step 4: Commit**

```bash
git add NAMESPACE man/ README.md
git commit -m "Regenerate docs for viya_login()/viya_reachable() and update README"
```

---

## Task 11: `CLAUDE.md`

**Files:**
- Create: `CLAUDE.md` (repo root)

**Interfaces:** None — documentation only.

- [ ] **Step 1: Write `CLAUDE.md`**

Create `CLAUDE.md` at the repo root:

```markdown
# viyar

R package connecting to SAS Viya over REST only (Compute, CAS Management,
Files/Folders) — no Python, no `swat` requirement for Compute. See
`README.md` for the user-facing quick start.

## Architecture

- `R/auth.R` — `viya_config()` (URL/context/cas_server/wb_integration
  resolution, with Workbench auto-detection of the URL) and `viya_token()`
  (the auth resolution chain below). `.token_cache` (an env) holds the
  active token/refresh token/expiry/client_id across calls in a session.
- `R/login.R` — `viya_login()`: interactive browser SSO (OAuth
  authorization code + PKCE) for use outside Workbench, plus its
  supporting helpers (PKCE generation, redirect/code parsing, token
  exchange).
- `R/utils.R` — `.viya_req()` is the single internal request builder
  every other file goes through: bearer auth, timeout, retry on
  transient 429/5xx, and Viya JSON error-body surfacing. Also
  `viya_reachable()` (network probe) and `.jwt_exp()` (token expiry
  decoding).
- `R/session.R` — compute session lifecycle: `viya_session()` (start,
  with reachability-gated retry through Viya errorCode 5830 pod-launch
  timeouts), `viya_end()`, `viya_sessions()`, `viya_kill()`,
  `viya_contexts()`.
- `R/submit.R` — `viya_submit()` (submit SAS code, poll, fetch log),
  `viya_librefs()`, `viya_datasets()`, `viya_members()`.
- `R/cas.R` — caslib table/file listing and `viya_load_table()`/
  `viya_unload_table()` (CAS memory management via `PROC CASUTIL`).
- `R/data.R` — `viya_read()`/`viya_write()` (R data.frame <-> SAS
  dataset, via the Compute data service and a CSV-staging `PROC IMPORT`).
- `R/files.R` — `viya_upload()`/`viya_download()` (Viya Files/Folders).

## The `viyar` S3 handle

Every function except `viya_login()`/`viya_config()`/`viya_token()`/
`viya_contexts()`/`viya_sessions()`/`viya_kill()`/`viya_reachable()` takes
a `viyar` handle (`h`) as its first argument — the object `viya_session()`
returns: `list(token, session, context, base)` tagged with class
`"viyar"`. `print.viyar()` is its only S3 method.

## Authentication (three paths into `viya_token()`)

Resolution order in `viya_token()`:

1. `VIYA_TOKEN` env var.
2. A still-fresh cached token (from either of the paths below).
3. Posit Workbench managed OAuth via `rstudioapi`, when
   `rstudioapi::isAvailable()` is `TRUE` and a matching integration
   exists (name regex: `viya_config()$wb_integration`, default
   `^sas-viya$`).
4. A cached SSO token from `viya_login()`, refreshed via its
   `refresh_token` if expired.
5. Otherwise: an error pointing at `viya_login()`/`VIYA_TOKEN`.

`viya_login(url, client_id = "vscode-positron")` drives an OAuth
authorization-code + PKCE flow against `{url}/SASLogon/oauth/authorize`
and `/SASLogon/oauth/token`: it opens a browser, you log in and paste
back the code (or the full redirect URL — either is accepted), and it
exchanges that for a token. This is the path to use for local
Mac/PC development and testing, where Workbench isn't available.

## Testing

Two tiers, both testthat 3e, run locally (no CI wiring yet):

- **Unit** (`tests/testthat/test-*.R`, excluding `test-live-*.R`): fully
  mocked via `httr2::local_mocked_responses()` and
  `testthat::local_mocked_bindings()` (for `rstudioapi` calls). No
  network, safe to run anywhere:
  `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
- **Live** (`tests/testthat/test-live-*.R`): real calls against
  `https://viya.pcluster.soleng.posit.it`. Before running these:
  1. `viya_config(url = "https://viya.pcluster.soleng.posit.it")`
  2. `viya_login()` (or set `VIYA_TOKEN` directly if you already have a
     token)
  3. Then run the same `test_dir()` command — `helper-live.R`'s
     `skip_if_no_viya()` auto-skips these tests when no URL/token is
     configured, so it's safe to run the full suite either way.

## Known gaps / follow-ups

- Live tests are not wired into CI (no Viya credentials available there)
  — they're a local developer/agent tool, not a merge gate.
- `viya_login()`'s `redirect_uri` handling was validated against the
  `vscode-positron` client on the `soleng` test cluster specifically;
  a different Viya deployment's client registration may need an explicit
  `redirect_uri` passed in.
- `viya_write()`/`viya_load_table()` warn (not error) on a non-"completed"
  job state — callers checking `r$state` themselves is still on them.
- Do not assume or hardcode a Viya test cluster for future testing work
  (Workbench example scripts, a second live-test file, a follow-up PR) —
  ask the user explicitly which URL to use each time. `viya.pcluster.soleng.posit.it`
  (used by this PR's live tests) stays as-is for this PR; don't retarget it.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add CLAUDE.md documenting architecture, auth chain, and test tiers"
```

---

## Task 12: Live test suite (requires an interactive SSO walkthrough with the user)

**This task cannot be delegated to a subagent that has no channel back
to the user** — `viya_login()` requires a human to open a URL, log in in
a real browser, and paste back a code/URL. Whoever executes this plan
must run this task themselves, in the same conversation as the user, not
hand it to an isolated subagent.

**Files:**
- Create: `tests/testthat/helper-live.R`
- Create: `tests/testthat/test-live-session.R`
- Create: `tests/testthat/test-live-data.R`
- Create: `tests/testthat/test-live-cas.R`

**Interfaces:**
- Consumes: every exported function built/hardened in Tasks 1-9.
- Produces: `skip_if_no_viya()` (no args -> skips the current test via
  `testthat::skip()` if `viya_config()$url` is empty or `viya_token()`
  throws). Used by every `test-live-*.R` file.

- [ ] **Step 1: Create the skip helper**

Create `tests/testthat/helper-live.R`:

```r
skip_if_no_viya <- function() {
  url <- viya_config()$url
  if (!nzchar(url)) testthat::skip("VIYA_URL/viya_config(url=...) not set")
  tok <- tryCatch(viya_token(), error = function(e) "")
  if (!nzchar(tok)) testthat::skip("no Viya token available (run viya_login())")
}
```

- [ ] **Step 2: Drive one live `viya_login()` round with the user**

This is a conversation, not a script. In the R console (or via a Bash
tool call running `Rscript -e`, since `viya_login()` uses `readline()`
which needs an interactive terminal — running it via plain `Rscript`
without a TTY will fail on `readline()`; use an actual interactive R
session, e.g. `R` in a terminal the user can also see, or ask the user to
run it and report back what they saw):

1. `viya_config(url = "https://viya.pcluster.soleng.posit.it")`
2. `viya_login(client_id = "vscode-positron")`
3. Observe and report back to the user: does the browser redirect to a
   URL with `code=` in it (a real `redirect_uri`), or does the Viya login
   page display a code directly with no redirect? Does omitting
   `redirect_uri` work, or does SASLogon reject the authorize request
   without one?
4. If the flow doesn't work as designed in Task 6 (e.g. it needs an
   explicit `redirect_uri`, or the pasted value has a different shape
   than expected), fix `viya_login()`/`.parse_auth_code()` in `R/login.R`
   now, re-run the mocked tests from Tasks 3-7 to confirm nothing broke,
   and commit the fix before continuing:

```bash
git add R/login.R
git commit -m "Fix viya_login() redirect/code handling based on live SASLogon behavior"
```

- [ ] **Step 3: Write the live session test**

Create `tests/testthat/test-live-session.R`:

```r
test_that("a real compute session starts and ends cleanly", {
  skip_if_no_viya()
  h <- viya_session()
  expect_s3_class(h, "viyar")
  expect_true(nzchar(h$session))

  libs <- viya_librefs(h)
  expect_true(is.character(libs))

  ended <- viya_end(h)
  expect_true(isTRUE(ended))
})

test_that("viya_contexts and viya_sessions return well-formed data frames", {
  skip_if_no_viya()
  ctxs <- viya_contexts()
  expect_true(all(c("name", "id") %in% names(ctxs)))
  expect_true(nrow(ctxs) > 0)

  sess <- viya_sessions()
  expect_true(all(c("id", "state") %in% names(sess)))
})
```

- [ ] **Step 4: Run against the live cluster**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS. If it fails, apply `superpowers:systematic-debugging`
before touching any test assertions — a live-cluster failure is real
signal, not a flaky test to loosen.

- [ ] **Step 5: Write the live data round-trip test**

Create `tests/testthat/test-live-data.R`:

```r
test_that("viya_write then viya_read round-trips a data.frame", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  df <- data.frame(id = 1:3, val = c(1.5, 2.5, 3.5))
  viya_write(h, df, "WORK", "VIYAR_TEST_RT")
  back <- viya_read(h, "WORK", "VIYAR_TEST_RT")

  expect_equal(nrow(back), 3)
  expect_equal(sort(back$ID), 1:3)
})

test_that("viya_upload then viya_download round-trips a file", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  tmp_up <- tempfile(fileext = ".txt")
  writeLines("viyar live test", tmp_up)
  viya_upload(h, tmp_up, "/Public", name = "viyar_live_test.txt")

  tmp_down <- tempfile(fileext = ".txt")
  viya_download(h, "/Public/viyar_live_test.txt", tmp_down)
  expect_equal(readLines(tmp_down), "viyar live test")
})
```

- [ ] **Step 6: Run against the live cluster**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS.

- [ ] **Step 7: Write the live CAS test**

Create `tests/testthat/test-live-cas.R`:

```r
test_that("caslib listing and load/unload round-trip", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  files <- viya_caslib_files(h, "Public")
  expect_true(all(c("name", "size") %in% names(files)))
  skip_if(nrow(files) == 0, "no source files in Public caslib to load")

  target <- files$name[1]
  viya_load_table(h, "Public", target, promote = FALSE)
  tables <- viya_caslib_tables(h, "Public")
  expect_true(all(c("name", "state") %in% names(tables)))

  casout <- toupper(sub("\\.[^.]+$", "", target))
  viya_unload_table(h, "Public", casout)
})
```

- [ ] **Step 8: Run the full suite (unit + live) one final time**

Run: `Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'`
Expected: PASS across all unit and live tests.

- [ ] **Step 9: Commit**

```bash
git add tests/testthat/helper-live.R tests/testthat/test-live-session.R \
        tests/testthat/test-live-data.R tests/testthat/test-live-cas.R
git commit -m "Add live integration tests against the soleng Viya test cluster"
```

---

## Task 13: Open the PR

**Files:** none (git/gh operations only).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin robustness-auth-and-tests
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "Add SSO login, harden REST error handling, and add a test suite" --body "$(cat <<'EOF'
## Summary
- Add `viya_login()`: interactive browser SSO (OAuth authorization code
  + PKCE) for using viyar outside Posit Workbench, wired into
  `viya_token()`'s resolution order with automatic refresh.
- Auto-detect the Viya URL from a Workbench OAuth integration when unset.
- Harden `.viya_req()` (every REST call): surfaces Viya's actual JSON
  error message/remediation instead of a generic HTTP error, retries
  transient 429/5xx responses. Fix `viya_reachable()` defaulting to
  disabled TLS verification. Add input validation to functions that were
  missing it.
- Add a two-tier testthat suite: mocked unit tests (offline, safe
  anywhere) and live tests against
  `https://viya.pcluster.soleng.posit.it` (auto-skipped without
  credentials).
- Add `CLAUDE.md` documenting the architecture, auth chain, and how to
  run each test tier for future work.

## Test plan
- [x] `pkgload::load_all("."); testthat::test_dir("tests/testthat")` — unit tests pass offline.
- [x] Live tests pass against the soleng test cluster after `viya_login()`.
- [x] `roxygen2::roxygenise()` regenerated docs/NAMESPACE cleanly.
EOF
)"
```

- [ ] **Step 3: Report the PR URL back to the user**

Do not merge it.

---

## Self-review notes (for whoever executes this plan)

- Every task's mocked assertions on `req$body$data$<field>` must unwrap
  httr2's `AsIs`-wrapped values with `as.character(...)` before
  comparing with `identical()` — comparing the `AsIs`-wrapped value
  directly against a plain string always returns `FALSE`. All test code
  above already does this; if you add more assertions in this style,
  remember it.
- `httr2::local_mocked_responses()`/`with_mocked_responses()` bypass
  `req_retry()` entirely (mocked responses return before the retry loop
  runs) — Task 1's retry test asserts on `req$policies$retry_max_tries`
  instead of simulating a retried call sequence, and Task 12's session
  retry-loop behavior can only be verified live or with a hand-rolled
  mock function that counts calls itself (as `viya_session()`'s own
  bespoke retry loop does, independent of `req_retry()`).
