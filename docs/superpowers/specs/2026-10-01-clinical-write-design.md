# Clinical Repository write support

Date: 2026-10-01
Branch: `feat-clinical-write`, stacked on `feat-clinical-repository` (PR #7)

## Goal

Let an R user change content in the SAS Clinical Acceleration Repository:
create containers, add files, check a file out, edit it locally and check it
back in with a comment, undo a check-out, rename, lock, and delete.

PR #7 ships the read-only half (`R/clinical.R`). This work adds the write
half.

**Out of scope:** version history (`/versions` endpoints). It goes on a
separate branch, built in parallel, because the test account cannot yet
create versioned files.

## Decisions already made

- **The workspace is hidden.** Check-out and check-in go through a per-user
  workspace on the server. Users never see it: check-out downloads the file
  to a local path, and check-in uploads a local path. There are no
  workspace functions in the public API.
- **Scope:** check out, check in, undo check-out, upload, create
  containers, delete, rename/edit attributes, lock/unlock.
- **Branching:** stacked on PR #7. The PR targets `feat-clinical-repository`
  until #7 merges, then moves to `main`.

## Facts established live (test cluster, 2026-10-01)

These were confirmed against a real deployment with a Clinical
Administrators account. They override developer.sas.com wherever the two
disagree.

- `POST /repository/items/{id}/children` takes `type` (`CONTEXT`/`FOLDER`),
  `typeId` and `name` as **query parameters**. A JSON body is ignored. It
  creates containers only; `type=FILE` is rejected.
- The `X-SAS-Clinical-Authorization: ADMIN` header is required to create a
  context under the root (item id `"1"`). Inside a context you created,
  sending the header gets `403 Access is denied`. Your own permissions
  apply there.
- `PUT /repository/items/{containerId}/content` (multipart, one `file`
  part) adds a new file. The stored name is the **file part's own
  filename**; a separate `filename` form field is ignored.
- The workspace route works: create folders with
  `POST /workspaces/@currentUser/folders?path=&name=`, upload with
  `PUT /workspaces/@currentUser/items?path=`, then
  `POST /workspaces/@currentUser/files?path=&action=CHECK_IN&comment=`.
  Workspace paths mirror repository paths.
- A file downloads raw with its own media type. A container downloads as a
  zip.
- `DELETE /repository/items/{id}` moves a file or folder to the recycle
  bin. A context can only be deleted with `?permanent=true`, which needs
  the "Permanently Delete Items" privilege. The admin header does not help.
- `.R` and `.r` uploads are rejected on the test cluster ("Files with
  extension "R" cannot be uploaded").
- The test account lacks "Enable/Manage Versioning" (a versioned check-in
  gets 403; an unversioned one works) and "Permanently Delete Items".

## Not yet confirmed (probe before coding)

1. **Rename / edit:** `PATCH /repository/items/{id}` with `If-Match`. The
   spec documents it; the body shape (flat fields or nested `attributes`)
   is unclear.
2. **Lock / unlock:** there is no dedicated endpoint. Items carry a
   `locked` field and there is a "Manage Locking" privilege. The likeliest
   route is a `PATCH` of `locked`.
3. **Check-in of a checked-out file:** confirmed only for a new file. Check
   that `CHECK_OUT` → workspace `PUT` → `CHECK_IN` updates the existing
   repository file's content and comment.
4. **Check-out state:** whether `checkedOut` and the check-out owner show on
   the repository item afterwards. The tests need this to assert on.

If probe 2 finds no working lock route, or the test account lacks the
privilege, lock/unlock is **dropped** from this PR and the reason recorded
in CLAUDE.md. Nothing ships that has only been tested against mocks.

## Public API

All functions follow PR #7's pattern: `token = viya_token()`,
`url = viya_config()$url`, and no compute session. Each returns the item's
updated metadata (the list `viya_clinical_item()` returns), invisibly.

| Function | Behaviour | REST calls |
|---|---|---|
| `viya_clinical_create(path, type_id = "folder")` | Creates one context or folder at `path`. Its parent must exist. Sends the admin header only when the parent is the root. | `POST .../children?type=&typeId=&name=` |
| `viya_clinical_upload(local_path, path, name = basename(local_path))` | Adds a new file to the container at `path`. | `PUT .../{containerId}/content` |
| `viya_clinical_checkout(path, local_path = NULL, overwrite = FALSE)` | Checks the file out to the caller; downloads it if `local_path` is given. Errors if `local_path` exists and `overwrite` is `FALSE`. | `CHECK_OUT`, then `POST .../{id}/content` |
| `viya_clinical_checkin(path, local_path, comment = NULL)` | Uploads the local copy and checks it in. | workspace `PUT`, then `CHECK_IN` |
| `viya_clinical_undo_checkout(path)` | Releases the check-out. Local files are untouched. | `UNDO_CHECKOUT` |
| `viya_clinical_delete(path, permanent = FALSE)` | Deletes an item, by default to the recycle bin. | `DELETE .../{id}` |
| `viya_clinical_update(path, name = NULL, description = NULL)` | Renames an item and/or edits its description. | `PATCH` with `If-Match` |
| `viya_clinical_lock(path)`, `viya_clinical_unlock(path)` | Locks or unlocks a file. Ships only if probe 2 succeeds. | to be confirmed |

`type_id` is checked against `viya_clinical_types()` before any write, so a
typo fails with the valid choices listed, not a server 400.

## Code layout

New file `R/clinical-write.R`. `R/clinical.R` stays read-only. Shared
helpers:

- `.viya_clinical_ws_action(h, path, action, ...)`: the one
  `POST /workspaces/@currentUser/files` request behind check-out, check-in
  and undo.
- `.viya_clinical_parent(path)`: splits a path into parent path and name.
- `.viya_clinical_patch(h, id, body)`: `GET`s the item for its `ETag`, then
  `PATCH`es with `If-Match`. This is the same read-then-write pattern as
  `viya_fs_delete()`, and it avoids the `428` the spec documents when the
  header is missing.

All requests go through `.viya_req()`, so bearer auth, the timeout, retries
and error-body handling stay in one place.

## Errors

The server's own error message reaches the user through `.viya_req()`'s
error handling. Its messages are already specific (for example "You have
not been granted the privilege …").

viyar adds one hint of its own. When a context delete fails because
`permanent` was not set, the error says to pass `permanent = TRUE` and
names the privilege it needs.

Argument checks (non-empty paths, an existing `local_path`, a valid
`type_id`) run before any request.

## Testing

**Unit tests** (`tests/testthat/test-clinical-write.R`, mocked with
`httr2::local_mocked_responses()`): for each function, assert the method,
URL, query parameters, headers and multipart file name sent. Each trap
found live gets its own test:

- `name`/`type`/`typeId` go in the query, not the body;
- the admin header is sent only when creating under the root;
- the upload name goes on the file part;
- `If-Match` carries the `ETag` from the preceding `GET`;
- check-out refuses to overwrite an existing local file;
- the context-delete hint appears.

**Live tests** (`tests/testthat/test-live-clinical-write.R`):

- **Fixture:** one long-lived organization, `/viyar_live_tests`. The first
  run creates it (admin); later runs reuse it. A run never creates another
  organization, because the test account cannot delete one.
- **Per run:** create `/viyar_live_tests/run_<timestamp>`, work inside it,
  and delete it at the end in a `withr::defer()`, so it is removed even
  when a test fails. Deleted folders go to the recycle bin.
- **Coverage:** create a folder → upload a `.sas` file → list it → check out
  and download → edit locally → check in with a comment → confirm the new
  content and comment → check out again and undo → rename → lock/unlock (if
  shipped) → delete.
- Tests that need a privilege the account lacks call `skip()` with the
  privilege named.
- `skip_if_no_clinical()` gates the whole file, as for the read tests.

Done means: the unit suite passes, and the live write tests pass in full
against the test cluster.

## Docs

- Roxygen for every exported function, with examples.
- A README section on editing repository files.
- CLAUDE.md: move the write facts from "confirmed live, not wrapped" to the
  `R/clinical-write.R` entry; record the probe results; record any dropped
  function and why.

## Known leftovers

Two test organizations from 2026-10-01 stay on the test cluster
(`/viyar_live_test_1790887509` and an empty `/viyar_live_test_tmp_*`).
Removing them needs someone with "Permanently Delete Items".
