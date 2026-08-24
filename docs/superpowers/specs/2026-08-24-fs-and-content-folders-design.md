# viyar: folder creation + OS-filesystem upload/download

Date: 2026-08-24
Status: approved by user, pending implementation plan

## Context

`viyar` already talks to SAS Content (the Files/Folders REST service) for
`viya_upload()`/`viya_download()`, but has no way to create a folder there.
Separately, SAS Viya Compute sessions have their own, completely
different "File System" REST resource that operates directly on the real
OS filesystem the session sees (its pod's local disk, or whatever's
mounted there — home directories, NFS-mounted shared paths, etc.) —
`viyar` doesn't use this at all yet.

This work adds folder creation for SAS Content, and a full new
upload/download/list/mkdir capability for the OS-level filesystem side,
scoped to an active compute session.

All API details below were confirmed two ways: against SAS's authoritative
OpenAPI specs (`developer.sas.com/api/apis/{folders-v5,compute-v23}/...`,
fetched directly — not GitHub examples, which are known to lag behind API
changes), and then empirically verified live against
`https://viya.pcluster.soleng.posit.it` before being written into this
spec. Nothing here is guessed.

## 1. SAS Content: `viya_create_folder(h, path)`

New function in `R/files.R`, alongside the existing `viya_upload()`/
`viya_download()`.

**Endpoint** (confirmed via `folders-v5`'s OpenAPI spec):
`POST /folders/folders?parentFolderUri={parent_uri}`,
`Content-Type: application/vnd.sas.content.folder+json` (or plain
`application/json`, both accepted), body `{"name": "LeafName"}`.

**Behavior**: creates missing intermediate folders (`mkdir -p` style, per
user decision). The Folders API only creates one level at a time — there
is no nested/recursive create — so this walks the path itself:

1. Split `path` into segments (e.g. `/Public/Reports/2026` → `Public`,
   `Reports`, `2026`).
2. For each prefix (`/Public`, `/Public/Reports`, `/Public/Reports/2026`
   in turn): try to resolve it via the existing `.viya_folder()` helper
   (which already does `GET /folders/folders/@item?path=...`). If it
   404s, create it as a child of the previous prefix's folder id (or as a
   root folder, `parentFolderUri=none`, for the first segment) via the
   POST above.
3. Return the final (leaf) folder's resource info, invisibly — matching
   `viya_upload()`'s return convention.

## 2. OS filesystem: new `R/fs.R`, `viya_fs_*` functions

All of these require an active compute session (`h$session`) — the
filesystem they operate on is scoped to that session, unlike the SAS
Content functions above.

### Path escaping (confirmed, not assumed)

Every path segment embedded in the URL for these endpoints must have each
`/` replaced with the literal string `~fs~` — SAS's own escaping
convention for this API specifically (confirmed in the OpenAPI spec's
parameter descriptions, and empirically: `viyar_fs_test1~fs~level2` is
how a two-level path is written in the URL). A single `.` in the URL
segment refers to the session's current working directory.

### `viya_fs_mkdir(h, path)`

**Endpoint**: `POST /compute/sessions/{id}/files/{parent_path}`, body
`{"name": "leaf", "isDirectory": true}`.

**Critical, empirically-confirmed detail**: the URL segment is the
**parent** directory, and the body's `name` is the new child's name — NOT
the full path in the URL. Passing the full desired path as the URL
segment (with `name` repeating the leaf) doubles the path and 404s
(reproduced live). There is also **no nested/recursive creation** —
creating `a/b/c` in one call 404s if `a/b` doesn't already exist
(reproduced live, both via the URL-segment path and via the body's
optional `path` attribute). So `viya_fs_mkdir()` walks the path exactly
like `viya_create_folder()` does for SAS Content: split into segments,
and for each prefix, `GET .../files/{prefix}` to check existence (404 ⇒
missing), then `POST .../files/{parent}` with `{name, isDirectory: true}`
to create it.

### `viya_fs_upload(h, local_path, remote_path)`

**Endpoint**: `PUT /compute/sessions/{id}/files/{remote_path}/content`,
`Content-Type: application/octet-stream`, raw file bytes as the body
(`httr2::req_body_file()`, same pattern as the existing `viya_upload()`).
Creates the file if it doesn't exist, replaces it if it does (confirmed:
no error on first creation without an `If-Match` header — that header is
only needed if you want optimistic-concurrency-safe replacement of an
existing file, which is out of scope for this pass).

### `viya_fs_download(h, remote_path, local_path)`

**Endpoint**: `GET /compute/sessions/{id}/files/{remote_path}/content` →
raw bytes via `httr2::resp_body_raw()` + `writeBin()`, same pattern as the
existing `viya_download()`.

### `viya_fs_list(h, path)`

**Endpoint**: `GET /compute/sessions/{id}/files/{path}/members` (paginated,
`start`/`limit` query params, default page size 10 per the spec — plan to
default to a larger `limit` matching the rest of the package's list
functions, e.g. 500). Returns a data.frame with `name`, `isDirectory`,
`size`, `path`, `modifiedTimeStamp` — parsed from each item's
`fileProperties` object in the returned collection.

## Testing

Same two-tier convention as the rest of the package: mocked unit tests
(new `tests/testthat/test-files.R` additions for `viya_create_folder()`,
new `tests/testthat/test-fs.R` for the `viya_fs_*` functions) plus live
tests (new `tests/testthat/test-live-fs.R`), gated by the existing
`skip_if_no_viya()` helper. Live tests will be run against whichever
cluster the user points at when we get to that point (per the standing
rule: never assume a test cluster).

## Delivery

Lands as more commits on the currently-open PR #1
(`robustness-auth-and-tests`), per user decision — not a new branch.

## Out of scope for this pass

- Deleting folders/files on either system (a `DELETE` call on the OS-file
  side was observed to return `428 Precondition Required` during live
  testing — likely needs an `If-Match` header or a specific query
  parameter for recursive delete; not investigated further since delete
  wasn't requested).
- Renaming/copying (both APIs support this, per their OpenAPI specs, but
  it wasn't asked for).
- Any REST-based creation semantics beyond one-level-at-a-time — both
  systems require the walk-and-create-each-segment approach described
  above; there is no server-side recursive create on either side.
