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
