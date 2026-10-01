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
