# Clinical Repository write support

Date: 2026-10-01
Branch: `feat-clinical-write`, stacked on `feat-clinical-repository` (PR #7)

## Goal

Let an R user change content in the SAS Clinical Acceleration Repository:
create containers, add files, check a file out, edit it locally and check it
back in with a comment, undo a check-out, rename, and delete.

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
  containers, delete, rename/edit attributes. Lock/unlock was in scope
  but is dropped (see probe 2).
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

## Probe results (run 2026-10-01, before coding)

1. **Rename / edit works.** `PATCH /repository/items/{id}` takes a **flat**
   JSON body (`{"name": "..."}`, `{"description": "..."}`) and needs
   `If-Match` with the item's current `ETag` (taken from a `GET` of the
   item). Without it: `428 The request header field "If-Match" is
   required.` Success is `200`, with the updated item as the body.
2. **Lock / unlock is dropped.** `PATCH {"locked": true}` answers `400
   Property "locked" is not a valid property on the resource.` No lock
   endpoint exists: `POST`/`PUT .../lock`, `PUT .../locked` and
   `.../state?value=locked` all `404`. The spec defines no lock action. The
   reason goes in CLAUDE.md.
3. **Check-in of a checked-out file works.** `CHECK_OUT` → workspace `PUT`
   → `CHECK_IN&comment=` replaces the repository content, sets
   `fileComment` and clears the check-out.
4. **Check-out state is visible.** After `CHECK_OUT` the repository item
   carries `checkedOut = TRUE`, `checkedOutBy` and `checkedOutTimestamp`.
   Error cases:
   - `CHECK_OUT` of a file you already have checked out: `409 File was
     not checked out because it is already checked out by you.`
   - `CHECK_IN` or `UNDO_CHECKOUT` of a file that isn't checked out: `400
     ... is not currently checked out, is not a file or does not exist.`
   - `UNDO_CHECKOUT` returns `200` with an empty body; `CHECK_OUT` and
     `CHECK_IN` return the workspace file as JSON.
   - `CHECK_OUT` creates the workspace folders the file needs, so the
     workspace `PUT` at check-in never hits a missing parent.

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
- **Per test:** each test creates its own
  `/viyar_live_tests/run_<timestamp>_<random>` folder, works inside it,
  and deletes it when the test ends in a `withr::defer()`, so it is
  removed even when a test fails. Deleted folders go to the recycle bin.
- **Coverage:** create a folder → upload a `.sas` file → list it → check out
  and download → edit locally → check in with a comment → confirm the new
  content and comment → check out again and undo → rename → delete.
- Tests that need a privilege the account lacks call `skip()` with the
  privilege named.
- `skip_if_no_clinical()` gates the whole file, as for the read tests.

Done means: the unit suite passes, and the live write tests pass in full
against the test cluster.

## Docs

- Roxygen for every exported function, with examples.
- A README section on editing repository files.
- CLAUDE.md: move the write facts from "confirmed live, not wrapped" to the
  `R/clinical-write.R` entry; record the probe results; record why
  lock/unlock was dropped.

## Known leftovers

Two test organizations from 2026-10-01 stay on the test cluster
(`/viyar_live_test_1790887509` and an empty `/viyar_live_test_tmp_*`).
Removing them needs someone with "Permanently Delete Items".
