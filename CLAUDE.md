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
- `R/submit.R` — `viya_submit()` (submit SAS code, poll, fetch output),
  `viya_librefs()`, `viya_datasets()`, `viya_members()`.
  `viya_submit()`'s `output` argument selects which of the job's three
  output endpoints to fetch: `"log"` (the default, and the only one
  fetched before this argument existed), `"listing"`
  (`/jobs/{id}/listing` — same `items[].line` collection shape as the
  log, so both go through `.viya_job_lines()`), and `"html"`
  (`/jobs/{id}/results`, whose items mix `type = "ODS"` output with
  `type = "TABLE"` entries describing datasets the job created; only
  the ODS ones are downloaded, each via its own `content`-or-`self`
  link). Fetching is gated on the argument, so an unrequested kind
  costs no request and produces no list element —
  `test-submit.R` pins this. **`viyar` deliberately does not wrap the
  submitted code in ODS statements** (SASPy does; this was an explicit
  design decision, not an omission): a destination produces output only
  when the user's own code opens it, and a compute server starts with
  `ods listing` closed, so `$listing` is empty for unwrapped code. For
  `$html`, the user's `ods html5` must carry **no** `file=` — a
  fileref-less destination is what the compute server routes to its
  results endpoint. Do **not** copy SASPy's `file=_tomods1` here:
  `_tomods1` is a fileref SASPy assigns itself, not a Compute built-in,
  and it fails live with `ERROR: No logical assign for filename
  _TOMODS1.` (confirmed live on a real cluster; it was
  written into this package's docs from the SASPy pattern and corrected
  only after a live run disproved it). Result items are named for the
  generated file (`sashtml.htm`, `sashtml2.htm`, ...), not for the
  procedure that produced them.
- `R/cas.R` — caslib table/file listing and `viya_load_table()`/
  `viya_unload_table()` (CAS memory management via `PROC CASUTIL`).
- `R/data.R` — `viya_read()`/`viya_write()` (R data.frame <-> SAS
  dataset, via the Compute data service and a CSV-staging `PROC IMPORT`).
  `viya_read()` sends **`format=false`** on the `/rows` request. The
  endpoint's own default is `format=true`, which returns *formatted
  display text* rather than stored values — that default silently broke
  every formatted numeric column: a `date9.` column arrived as
  `"01JAN2020"` and a `dollar12.2` column as `"$1,234.50"`, both of which
  `as.numeric()` turns into `NA` (a CDISC ADaM read came back 254/254 NA
  on `TRTSDT`), and a `10.4` column arrived pre-rounded to four decimals
  (which manufactured a false 4.3e-5 SAS-vs-R discrepancy in a
  `PROC LIFETEST` chi-square before the cause was found). Two things to
  know about this parameter: SAS's own GitHub API samples call it
  `formatted`, not `format` — developer.sas.com's current `getRows`
  reference says `format`, and an unrecognised query parameter is
  *silently ignored*, so a wrong name looks exactly like the bug coming
  back; and with `format=false` the digits SAS emits depend on the
  session's `DECIMALCONV` option (`STDIEEE` is the documented setting for
  full significant digits) — untested, so a right-value/too-few-digits
  failure in `test-live-data.R` points here, not at the fix.
  Date conversion is **not** automatic and cannot be: the Compute
  `columns` endpoint reports a format's `decimals` and `length` but never
  its *name*, so nothing in the response identifies a date column. Hence
  `viya_read(dates = c("TRTSDT", ...))` — matched case-insensitively
  (SAS preserves defined case), resolved before the first row is fetched,
  and an error (never a silent no-op) on a name that is absent or belongs
  to a character column. Sibling parameters on the same endpoint, all
  currently unused: `formatMissingValues`, `returnNumAsString`,
  `includeColumnNames`, `includeIndex`, `where`.
- `R/files.R` — `viya_upload()`/`viya_download()`/`viya_create_folder()`/
  `viya_delete_file()`/`viya_delete_folder()` (SAS Content: the
  Files/Folders service). Both deletes resolve the target to its
  resource `id`/`uri` first (via `.viya_folder()` or a folder's
  `members` listing), then `DELETE` by that id -- no `ETag`/`If-Match`
  needed here (unlike `R/fs.R` below). `viya_delete_folder()` always
  sends `?recursive=true` (a no-op for an empty folder, required for a
  non-empty one) rather than branching on emptiness.
- `R/fs.R` — `viya_fs_mkdir()`/`viya_fs_upload()`/`viya_fs_download()`/
  `viya_fs_list()`/`viya_fs_delete()`: a second, distinct storage system
  -- the real OS filesystem a compute session sees (home directory,
  NFS-mounted shared paths, etc.), via the Compute service's own "File
  System" REST resource. `viya_fs_delete()` deletes both files and
  non-empty directories through the same call (no recursive flag), but
  unlike the SAS Content deletes above, this API requires an `If-Match`
  header carrying the resource's current `ETag` -- so it does a `GET`
  first to read the `ETag` off the response headers, then `DELETE`s with
  it; omitting `If-Match` gets a `428 Precondition Required`.
  `.viya_fs_escape()` joins path segments with the literal
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
3. Posit Workbench managed OAuth via `rstudioapi::findOAuthIntegration()`/
   `getOAuthCredentials()` (name regex: `viya_config()$wb_integration`,
   default `^sas-viya$`). **Deliberately does NOT gate on
   `rstudioapi::isAvailable()`.** Found live (a real bug, shipped and then
   corrected): `isAvailable()` checks a stricter, unrelated condition —
   "is this process an RStudio-family GUI frontend" — which is `FALSE`
   inside any child process (an RStudio/Positron background Job, a
   notebook's own execution kernel, or the process `quarto render` knits
   a document in), even when the parent session is genuinely
   Workbench-connected. But `findOAuthIntegration()`/
   `getOAuthCredentials()` don't actually depend on that at all — they
   internally call `assertWorkbenchSession()`, a plain check of the
   `POSIT_PRODUCT`/`RS_SERVER_ADDRESS` env vars (mirrored here by
   `.viya_in_workbench_session()`), which every subprocess inherits. So
   `viya_config()`/`viya_token()` call these functions unconditionally
   (once `rstudioapi` is confirmed installed) and let `tryCatch` handle
   the "not in Workbench at all" case by falling through — this makes
   auto-detection work correctly from `quarto render`/a background Job/a
   notebook kernel, as long as that process is genuinely running inside a
   Workbench session. A `child_ok = TRUE` fix was tried first and shipped
   briefly; it only relayed through a live RStudio Job RPC channel and
   didn't address the real cause, so it was replaced by this fix.
   `.viya_no_url_error()` (in `R/auth.R`) appends a hint to the "No Viya
   URL configured" error specifically when `.viya_in_workbench_session()`
   is `FALSE` — i.e. not in Workbench at all (local desktop R, or
   `quarto render` run entirely outside Workbench).
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
  **Known gap:** this covers config/auth/login/utils/input-validation and
  `viya_submit()`'s `output` handling (log/listing/html selection, ODS
  item filtering, link resolution) and `viya_read()`'s value handling
  (`test-data.R`: the `format=false` query parameter, `dates`
  conversion/matching/validation), but `viya_session()`'s retry loop,
  `viya_submit()`'s poll/timeout loop, `viya_read()`'s paging,
  `viya_write()`, `viya_upload()`/`viya_download()`, and the CAS
  listing/load functions have no mocked happy-path coverage — only the
  live tier exercises them (real signal when run, but not a merge gate).
  This was a scope decision made explicitly during the final whole-branch
  review of this PR, not an oversight: closing it needs its own
  per-function review cycle rather than a rushed addition. Treat as the
  top priority for a follow-up PR.
- **Live** (`tests/testthat/test-live-*.R`): real calls against a real
  Viya deployment. Nothing in the suite hardcodes a host -- point it at
  your own cluster. Before running these:
  1. `viya_config(url = "https://your-viya-host")`, or set `VIYA_URL`
  2. `viya_login()` (or set `VIYA_TOKEN` directly if you already have a
     token)
  3. Then run the same `test_dir()` command — `helper-live.R`'s
     `skip_if_no_viya()` auto-skips these tests when no URL/token is
     configured, so it's safe to run the full suite either way.

## Known gaps / follow-ups

- Live tests are not wired into CI (no Viya credentials available there)
  — they're a local developer/agent tool, not a merge gate.
- `test-live-submit.R` passed in full against a live cluster (2026-08-25,
  all 8 assertions). Two findings from that run are worth keeping:
  - A job's `state` is `"completed"` as expected, but SAS's error state
    is **sticky within a session**: once one submission fails, every
    later job in that same session reports `"error"` even with a clean
    log and no `ERROR` lines of its own — a plain `proc print` was
    observed reporting `"error"` purely because an earlier submission in
    that session had failed. When diagnosing a surprising `"error"`
    state, check whether anything earlier in the session failed before
    suspecting the code you just submitted; a fresh `viya_session()` is
    the way to isolate it.
  - An ODS result item carries exactly **one** link, with
    `rel = "self"`, `method = "GET"`, `type = "text/html"` — there is no
    `content` relation, so `.viya_result_path()` reaches the content via
    its `self` fallback. Its `href` is
    `/compute/sessions/{id}/results/{hash}/{filename}` — under the
    *session*, not under `/jobs/{jobId}/` where the collection was
    listed. Follow the returned `href`; do not construct the content URL
    from the job path.
- The cluster returns intermittent HTTP 500
  `process initialization for the Compute server ... failed` on session
  creation — seen on the first attempt of most `viya_session()` calls in
  that run, with the retry loop recovering on attempt 2-4 every time.
  This is what `viya_session()`'s `tries`/`wait` retry exists for; a
  single 500 is not a defect. A run with `tries = 1` will fail often.
- `viya_login()`'s `redirect_uri` defaults to the OAuth out-of-band value
  (`urn:ietf:wg:oauth:2.0:oob`), which is SAS's own documented pattern for
  CLI-style paste-back logins — confirmed against developer.sas.com, not
  assumed. `client_id = "vscode-positron"` is NOT itself a SAS-documented
  default client (SAS's VS Code extension docs name `vscode`) — it only
  works if separately registered on the target Viya deployment. Validated
  against one specific test cluster; if login ever fails with an
  invalid-client error on a different deployment, this is why.
- `viya_write()`/`viya_load_table()` warn (not error) on a non-"completed"
  job state — callers checking `r$state` themselves is still on them.
- The primary test cluster's CAS server was found stuck in
  `"starting"` (a DNS lookup failure for its backend pod, confirmed via
  `GET /casManagement/servers/{server}/state`) during Task 12's live
  validation — a cluster infrastructure issue, not a viyar defect.
  `test-live-cas.R` was instead validated against a second cluster, whose
  CAS server was healthy. If `test-live-cas.R` 404s while the other live
  tests pass, check that cluster's CAS state before assuming a regression.
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
  ask the user explicitly which URL to use each time. Whatever cluster a
  given PR's live tests were validated against stays as-is for that PR;
  don't retarget it.
- A documentation audit against developer.sas.com/rest-apis (cross-checked
  live, not from GitHub examples — those are known to lag behind API
  changes) surfaced further gaps worth a follow-up PR, not addressed here:
  - **Pagination**: every list-returning function (`viya_contexts`,
    `viya_sessions`, `viya_caslib_files`, `viya_caslib_tables`,
    `viya_librefs`, `viya_datasets`, folder `members`, `viya_read()`'s
    `columns` call, and `viya_submit()`'s log/listing/results fetches)
    takes one page at a single hardcoded `limit` and never
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
- `viya_fs_delete()`'s two-request GET-then-DELETE is not atomic: if the
  resource is deleted or modified by something else between the two
  calls, the `ETag` from the `GET` will be stale and the `DELETE` will
  (correctly) fail rather than delete the wrong version — this is the
  API's own optimistic-concurrency design, not a `viyar` bug, but worth
  knowing if a delete call intermittently 412/428s under concurrent
  access to the same path. Also: `viya_delete_file()`/
  `viya_delete_folder()` (SAS Content) were designed and mocked-tested
  against documented/previously-confirmed behavior only — this PR had no
  live cluster access, so double-deleting an already-gone resource,
  deleting a folder mid-populate, and the exact `viya_fs_delete()`
  `ETag` format on a real cluster are all unverified beyond the mocked
  tests; `test-live-fs.R`/`test-live-files.R` are written and ready for
  whoever runs the live tier next.
