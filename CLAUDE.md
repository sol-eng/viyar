# viyar

R package connecting to SAS Viya over REST only (Compute, CAS Management,
Files/Folders) — no Python, no `swat` requirement for Compute. See
`README.md` for the user-facing quick start.

## Architecture

- `R/auth.R` — `viya_config()` (URL/context/cas_server/wb_integration
  resolution, with Workbench auto-detection of the URL) and `viya_token()`
  (the auth resolution chain below). `.token_cache` (an env) holds the
  active token/refresh token/expiry/client_id/login-url across calls in a
  session — the login URL is cached so a silent refresh always targets
  the server actually logged into, not whatever `viya_config()$url`
  happens to be at refresh time.
- `R/login.R` — `viya_login()`: interactive browser SSO (OAuth
  authorization code + PKCE) for use outside Workbench, plus its
  supporting helpers (PKCE generation, redirect/code parsing, token
  exchange — the exchange call has its own 30s timeout, since it's the
  one REST call in the package that doesn't go through `.viya_req()`).
- `R/utils.R` — `.viya_req()` is the single internal request builder
  every other file goes through: bearer auth, timeout, retry on
  transient 429/503 (matching httr2's own safe default — 500/502/504 are
  deliberately excluded since this package makes non-idempotent POSTs:
  starting sessions, submitting SAS code, uploading files), and Viya JSON
  error-body surfacing (via exact-match `[[`, not `$`, to avoid partial
  name matches producing garbled text). Also `viya_reachable()` (network
  probe, TLS-verifying by default; opt out via the `viyar.insecure`
  option) and `.jwt_exp()` (token expiry decoding).
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
- `R/files.R` — `viya_upload()`/`viya_download()`/`viya_create_folder()`
  (SAS Content: the Files/Folders service).
- `R/fs.R` — `viya_fs_mkdir()`/`viya_fs_upload()`/`viya_fs_download()`/
  `viya_fs_list()`: a second, distinct storage system -- the real OS
  filesystem a compute session sees (home directory, NFS-mounted shared
  paths, etc.), via the Compute service's own "File System" REST
  resource. `.viya_fs_escape()` joins path segments with the literal
  `~fs~` (SAS's own escaping convention, confirmed empirically, not
  documented in prose form anywhere) and then URL-encodes the result
  (`~` survives encoding untouched; a genuinely critical detail --
  **a leading `/` must become a leading `~fs~` too**, since that's what
  distinguishes an absolute path from one resolved against the session's
  cwd. Losing that distinction was a real bug caught only in a final
  review: every absolute-path example silently became cwd-relative
  instead of erroring). Neither this API nor the Folders API supports
  recursive/nested creation -- `viya_create_folder()`/`viya_fs_mkdir()`
  both walk the path themselves, creating one missing segment at a time.

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
   `^sas-viya$`). **`isAvailable()` requires a live IDE-connected R
   process** — found live: `quarto render` (and plain `Rscript`) launch a
   separate, detached R process to knit a document, so this auto-detection
   silently doesn't run there even though the exact same code works when
   run as an interactive cell or in the R console. `.viya_no_url_error()`
   (in `R/auth.R`) detects this case (`rstudioapi` installed but not
   connected) and appends a hint to the "No Viya URL configured" error
   telling the user to set `VIYA_URL`/`viya_config(url = ...)` explicitly
   before rendering non-interactively.
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
  **Known gap:** this covers config/auth/login/utils/input-validation, but
  `viya_submit()`, `viya_session()`'s retry loop, `viya_read()`/
  `viya_write()`, `viya_upload()`/`viya_download()`, and the CAS
  listing/load functions have no mocked happy-path coverage — only the
  live tier exercises them (real signal when run, but not a merge gate).
  This was a scope decision made explicitly during the final whole-branch
  review of this PR, not an oversight: closing it needs its own
  per-function review cycle rather than a rushed addition. Treat as the
  top priority for a follow-up PR.
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
- `viya_login()`'s `redirect_uri` defaults to the OAuth out-of-band value
  (`urn:ietf:wg:oauth:2.0:oob`), which is SAS's own documented pattern for
  CLI-style paste-back logins — confirmed against developer.sas.com, not
  assumed. `client_id = "vscode-positron"` is NOT itself a SAS-documented
  default client (SAS's VS Code extension docs name `vscode`) — it only
  works if separately registered on the target Viya deployment. Validated
  against the `soleng` test cluster specifically; if login ever fails with
  an invalid-client error on a different deployment, this is why.
- `viya_write()`/`viya_load_table()` warn (not error) on a non-"completed"
  job state — callers checking `r$state` themselves is still on them.
- `viya.pcluster.soleng.posit.it`'s CAS server was found stuck in
  `"starting"` (a DNS lookup failure for its backend pod, confirmed via
  `GET /casManagement/servers/{server}/state`) during Task 12's live
  validation — a cluster infrastructure issue, not a viyar defect.
  `test-live-cas.R` was instead validated against
  `caf.pcluster.soleng.posit.it`, whose CAS server was healthy. If
  `test-live-cas.R` 404s while the other live tests pass, check that
  cluster's CAS state before assuming a regression.
- `viya_upload()`'s Files API has no overwrite-on-upload — a fixed
  filename collides with HTTP 409 on a second run against the same
  cluster (found live). `test-live-data.R`'s upload test uses a
  timestamped filename and deletes it via the Files API afterward.
- `viya_fs_*` operates on whatever the compute session's OS process can
  read/write — read access and write access are not the same thing, and
  a path can have one without the other. Found live: a user's own
  NFS-mounted home directory was listable (`viya_fs_list()` on its
  parent) and passed SAS's own `fileexist()`, but both `viya_fs_mkdir()`
  and SAS's own `dcreate()` failed identically trying to create anything
  under it — confirming a real write-permission/mount restriction on
  that specific deployment (NFS root-squash or a UID mismatch are the
  usual causes), not a `viyar` or REST API bug. `/tmp` was confirmed
  writable and to be the same filesystem view for both the REST API and
  SAS code (a file uploaded via `viya_fs_upload()` was read back
  correctly via a SAS `data _null_`/`infile` step) — useful as a
  scratch/diagnostic location, but session-scoped, not guaranteed
  persistent. If `viya_fs_mkdir()` 404s on a path that's confirmed to
  exist, test write access directly with SAS's `dcreate()` before
  assuming a code bug.
- Do not assume or hardcode a Viya test cluster for future testing work
  (Workbench example scripts, a second live-test file, a follow-up PR) —
  ask the user explicitly which URL to use each time. `viya.pcluster.soleng.posit.it`
  (used by this PR's live tests) stays as-is for this PR; don't retarget it.
- A documentation audit against developer.sas.com/rest-apis (cross-checked
  live, not from GitHub examples — those are known to lag behind API
  changes) surfaced further gaps worth a follow-up PR, not addressed here:
  - **Pagination**: every list-returning function (`viya_contexts`,
    `viya_sessions`, `viya_caslib_files`, `viya_caslib_tables`,
    `viya_librefs`, `viya_datasets`, folder `members`, and `viya_read()`'s
    `columns` call) takes one page at a single hardcoded `limit` and never
    follows the documented `links.next` hypermedia relation — a collection
    larger than that limit is silently truncated with no warning.
  - **Compute job polling**: `viya_submit()` busy-polls
    `/jobs/{id}/state` with `Sys.sleep()`; the Compute service documents a
    `wait=`/`If-None-Match` long-poll pattern (304 on no change) intended
    to replace exactly this kind of loop.
  - **CAS table loading**: `viya_load_table()` submits generated
    `PROC CASUTIL` code through the Compute service; CAS Management's own
    REST API documents a direct `PUT .../tables/{table}/state?value=loaded`
    action (with `replace`/`scope` options) that could do this without
    Compute-service code submission or the `_VIYARC_` session-naming
    convention.
  - **Error body richness**: `.viya_error_body()` only surfaces
    `message`/`remediation`; SAS's vendor error type likely also carries
    `errorCode`, `details`, and `httpStatusCode` — capturing `errorCode`
    structurally would let `viya_session()`'s retry logic match on it
    directly instead of substring-matching error text for code `5830`.
  - **File uploads**: `viya_upload()` never sends an explicit
    `Content-Type` header (only `Content-Disposition`); SAS's docs say
    each file needs "a specified name and content type" — unverified
    whether this causes wrong stored MIME types in practice.
