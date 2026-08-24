# viyar: SSO auth, robustness hardening, and a real test suite

Date: 2026-08-24
Status: approved by user, pending implementation plan

## Context

`viyar` (`sol-eng/viyar`) is an R package that talks to SAS Viya over its
REST APIs (Compute, CAS Management, Files/Folders) plus loads Viya access
tokens from Posit Workbench managed OAuth credentials. It has no automated
tests today, and the only way to get a Viya token outside Workbench/Connect
is to set `VIYA_TOKEN` by hand.

This work has three goals:

1. Let a developer on a local Mac/PC authenticate to Viya interactively
   (browser SSO), so the package can be tested end-to-end outside Workbench.
2. Harden the package generally: error messages, retries, input validation,
   token-expiry handling, and a TLS-verification bug in `viya_reachable()`.
3. Build a real regression test suite (unit + live) so future changes can be
   validated without a human re-testing every code path by hand.

Test cluster for live testing: `https://viya.pcluster.soleng.posit.it`,
OAuth client id `vscode-positron`.

## 1. SSO login subsystem

New file `R/login.R`.

```r
viya_login(url = viya_config()$url,
           client_id = "vscode-positron",
           redirect_uri = "urn:ietf:wg:oauth:2.0:oob",
           scope = "openid")
```

Flow:

1. Generate a PKCE `code_verifier` (random 43–128 char string) and
   `code_challenge` (`BASE64URL(SHA256(code_verifier))`) — the server's
   `/SASLogon/.well-known/openid-configuration` advertises
   `code_challenge_methods_supported: ["S256", "plain"]`, and PKCE is the
   correct choice for a public client with no secret.
2. Build the authorize URL:
   `{url}/SASLogon/oauth/authorize?client_id=...&response_type=code&scope=...&code_challenge=...&code_challenge_method=S256&redirect_uri=urn:ietf:wg:oauth:2.0:oob`.
   `urn:ietf:wg:oauth:2.0:oob` is SAS's own documented redirect value for
   CLI-style logins where the code is copy-pasted back rather than
   captured by a listening redirect target (confirmed against
   developer.sas.com's authentication docs, not assumed).
3. Open it with `utils::browseURL()` and also print it to the console (so
   it still works when there's no local browser to launch, e.g. over SSH).
4. Prompt (`readline`) for what the user sees after logging in. Accept
   either a bare authorization code or a full redirect URL and extract
   `code=` from either — the oob redirect should mean the code is
   displayed directly rather than an actual browser redirect happening,
   but the parsing stays tolerant of both shapes since this is confirmed
   only by driving one login live (Task 12), not by SAS's docs alone.
   `client_id = "vscode-positron"` itself is not a SAS-documented default
   client (SAS's own VS Code extension docs name `vscode` as the
   pre-registered built-in id) — it only works if it's been separately
   registered on the target Viya deployment, which the user has stated is
   the case for this PR's test cluster specifically.
5. Exchange the code at `/SASLogon/oauth/token`
   (`grant_type=authorization_code`, `code`, `code_verifier`, `client_id`,
   and `redirect_uri` if one was used in step 2).
6. Cache `access_token`, `refresh_token` (if present), and decoded JWT `exp`
   in the package's token-cache environment (same `.token_cache` used
   today).

`viya_token()` resolution order (extends the existing function, does not
replace it):

1. `VIYA_TOKEN` env var (unchanged)
2. Workbench managed OAuth via `rstudioapi` (unchanged)
3. Cached SSO token from `viya_login()` — if its `exp` claim says it's
   expired or near-expiry, silently refresh via `grant_type=refresh_token`
   before returning it; if refresh fails, fall through to step 4
4. Error: tell the user to call `viya_login()` or set `VIYA_TOKEN`

### Workbench URL auto-detection (spike, best-effort)

Check whether `rstudioapi::findOAuthIntegration()`'s return value exposes
the Viya server URL (audience/resource field) so `viya_config()` can
auto-populate `url` when running inside Workbench and no URL is
configured. This requires inspecting a real Workbench session/integration
object. If it doesn't expose a usable URL, this is a no-op and manual
`VIYA_URL`/`viya_config(url = ...)` configuration remains as-is — this
sub-item is not allowed to block the rest of the work.

## 2. Robustness hardening

Applies across `R/auth.R`, `R/session.R`, `R/cas.R`, `R/data.R`,
`R/files.R`, `R/submit.R`, `R/utils.R`.

- **Error messages**: `.viya_req()` gains `httr2::req_error(body = ...)` so
  Viya's JSON error body (`message`, `remediation` fields) surfaces in the
  R error instead of httr2's generic "HTTP 400" text.
- **Retries**: add `httr2::req_retry()` to `.viya_req()` for transient
  network/5xx failures. `viya_session()`'s existing bespoke retry loop
  (reachability gate + errorCode 5830 pod-launch retry) is untouched — it
  handles a different failure mode.
- **Input validation**: extend the `stopifnot(inherits(h, "viyar"))` /
  non-empty url-token pattern (already used in some functions) to the ones
  missing it: `viya_contexts`, `viya_sessions`, `viya_kill`,
  `viya_caslib_files`, `viya_caslib_tables`, `viya_unload_table`,
  `viya_load_table`, `viya_members`.
- **`viya_reachable()` TLS bug**: it currently hard-codes
  `ssl_verifypeer = FALSE, ssl_verifyhost = FALSE`. Default flips to
  verifying TLS; add an explicit `insecure = FALSE` parameter for anyone
  who genuinely needs to probe a self-signed cluster.
- **Token expiry**: decode the JWT `exp` claim (base64-decode the middle
  segment) so expiry is known ahead of time rather than discovered via a
  401 mid-workflow.

## 3. Testing (two tiers, testthat 3e)

Add `testthat (>= 3.0.0)` to `Suggests`, `Config/testthat/edition: 3` to
`DESCRIPTION`.

```
tests/testthat.R
tests/testthat/
  helper-live.R         # skip_if_no_viya(): skip live tests w/o URL+token
  test-config.R         # unit: viya_config() option/env resolution
  test-auth.R           # unit: token cache, VIYA_TOKEN precedence, refresh
  test-login.R          # unit: PKCE generation, code/URL parsing, token exchange (mocked)
  test-utils.R          # unit: .viya_req(), error body parsing, viya_reachable()
  test-session.R        # unit: context lookup, retry loop (mocked)
  test-submit.R         # unit: job polling/state handling (mocked)
  test-cas.R            # unit: caslib listing, load/unload code generation
  test-data.R           # unit: read/write column-type coercion, staging
  test-files.R          # unit: upload/download folder resolution
  test-live-session.R   # live: real session start/end against test cluster
  test-live-data.R      # live: real read/write/upload/download roundtrip
  test-live-cas.R        # live: real caslib load/unload roundtrip
```

- **Unit tests** use `httr2::local_mocked_responses()` (already available
  since httr2 is an existing `Imports` dependency — no new dependency
  needed). No network access required; safe to run anywhere including CI
  later.
- **Live tests** hit `https://viya.pcluster.soleng.posit.it` for real,
  gated by `skip_if_no_viya()` (skips unless a URL and a resolvable token
  are available). This is the suite the user and Claude will run together
  after an interactive `viya_login()`.
- No CI wiring in this PR (explicit user decision) — both tiers are
  run locally via `devtools::test()`.

## 4. `CLAUDE.md`

New file at the repo root covering:

- Package purpose and file-by-file architecture.
- The three auth methods and when each applies (`VIYA_TOKEN`, Workbench
  managed OAuth, `viya_login()` SSO), including the `viyar` S3 handle
  contract (`token`, `session`, `context`, `base`).
- How to run each test tier locally, including the `viya_login()` step
  needed before live tests will do anything.
- Coding conventions already in use: roxygen2 docs, httr2 native pipe
  style, `message()`-based progress logging, `%||%` null-coalesce helper.
- A running list of known gaps/follow-ups for future robustness work.

## 5. PR workflow

New branch off `main` (e.g. `robustness-auth-and-tests`), everything
above as commits, pushed, and a PR opened against `sol-eng/viyar` via
`gh pr create`. Not merged by Claude.

## Open items to resolve during implementation

- Exact shape of what `vscode-positron` redirects to after login (real
  `redirect_uri` vs. a display-only code page) — confirmed via one live
  login walkthrough with the user before finishing `viya_login()`.
- Whether `rstudioapi::findOAuthIntegration()` exposes a usable Viya URL
  for auto-detection inside Workbench — best-effort, non-blocking.
