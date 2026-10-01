# SAS Clinical Acceleration Repository (the /clinicalRepository service).
#
# Not a compute API: none of these functions need a compute session, so
# they take `token`/`url` directly the way viya_contexts()/viya_sessions()
# do rather than a `viyar` handle. `.viya_req()` only ever reads
# `$token`/`$base`, so a minimal two-field list is all it needs.

.viya_clinical_h <- function(token, url) {
  if (!nzchar(url %||% "")) stop(.viya_no_url_error())
  stopifnot(nzchar(token %||% ""))
  list(token = token, base = url)
}

.viya_link <- function(x, rel) {
  hit <- Filter(function(l) identical(l[["rel"]], rel), x[["links"]] %||% list())
  if (!length(hit)) NULL else hit[[1]][["href"]]
}

# Walks a SAS collection to the end by following its `next` hypermedia
# link. The Clinical Repository emits next/prev/first/last rels whenever a
# further page exists (confirmed live), and every href is already a
# service-absolute path, so it can go straight back into `.viya_req()`.
# Both guards below exist because a `next` link is server-supplied: one
# that points back at a page already fetched would otherwise spin
# forever, so the walk stops and says so rather than hanging.
.viya_clinical_collect <- function(h, path, max_pages = 100L) {
  out <- list()
  nxt <- path
  seen <- character()
  for (i in seq_len(max_pages)) {
    seen <- c(seen, nxt)
    r <- .viya_req(h, nxt) |> httr2::req_perform() |> httr2::resp_body_json()
    out <- c(out, r[["items"]] %||% list())
    nxt <- .viya_link(r, "next")
    if (is.null(nxt)) return(out)
    if (nxt %in% seen) {
      warning("the server's 'next' page link points back at a page already ",
              "fetched - the collection may be truncated")
      return(out)
    }
  }
  warning("stopped after ", max_pages,
          " pages - the collection may be truncated")
  out
}

.viya_clinical_items_df <- function(items) {
  chr <- function(field)
    vapply(items, function(x) x[[field]] %||% NA_character_, "")
  data.frame(
    name     = chr("name"),
    id       = chr("id"),
    type     = chr("primaryType"),
    type_id  = chr("typeId"),
    path     = chr("path"),
    size     = vapply(items,
                      function(x) as.numeric(x[["size"]] %||% NA_real_),
                      numeric(1)),
    state    = chr("state"),
    modified = chr("modifiedTimeStamp"),
    stringsAsFactors = FALSE)
}

#' Look up a Clinical Repository item by its path
#'
#' Resolves a path in the SAS Clinical Acceleration Repository to the item
#' stored there -- a context (organization, study, ...), a folder, or a
#' file. `"/"` is the repository root, which is always a `tenant` context.
#'
#' The Clinical Repository addresses items by numeric `id`, and every
#' other function here needs one, so this is the entry point that turns a
#' human-readable path into an addressable item.
#'
#' @param path Repository path, e.g. `"/Acme/Study 1/protocol.sas"`.
#'   Defaults to the repository root.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL. No compute
#'   session is needed -- if you already have one, pass `h$token` and
#'   `h$base`.
#' @return The item's metadata as a list. Always carries `id`, `path`,
#'   `typeId` (`"study"`, `"folder"`, `"sasprogram"`, ... -- see
#'   [viya_clinical_types()]) and `primaryType` (`"CONTEXT"`, `"FOLDER"`
#'   or `"FILE"`); most items also carry `name`, `size`, `state` and
#'   timestamps.
#' @examples
#' \dontrun{
#' viya_clinical_item()                     # the repository root
#' viya_clinical_item("/Acme/Study 1")$id
#' }
#' @export
viya_clinical_item <- function(path = "/", token = viya_token(),
                               url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(path))
  .viya_req(h, paste0("/clinicalRepository/repository/paths?path=",
                      utils::URLencode(path, reserved = TRUE))) |>
    httr2::req_perform() |> httr2::resp_body_json()
}

#' List the contents of a Clinical Repository container
#'
#' Lists everything directly inside a context or folder: nested contexts,
#' folders and files alike. Unlike the other list functions in this
#' package, this one is not capped at a single page -- it follows the
#' collection's `next` link until the server stops offering one, so a
#' container with more children than one page holds is still returned in
#' full.
#'
#' @param path Repository path of the container to list. Defaults to the
#'   repository root.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return A data frame with columns `name`, `id`, `type` (`"CONTEXT"`,
#'   `"FOLDER"` or `"FILE"`), `type_id`, `path`, `size` (bytes), `state`
#'   and `modified`. An empty container gives a zero-row frame with those
#'   same columns.
#' @examples
#' \dontrun{
#' viya_clinical_list()                     # top-level contexts
#' viya_clinical_list("/Acme/Study 1")
#' }
#' @export
viya_clinical_list <- function(path = "/", token = viya_token(),
                               url = viya_config()$url) {
  h  <- .viya_clinical_h(token, url)
  it <- viya_clinical_item(path, token, url)
  items <- .viya_clinical_collect(
    h, paste0("/clinicalRepository/repository/items/", it$id,
              "/children?limit=100"))
  .viya_clinical_items_df(items)
}

#' Download Clinical Repository content
#'
#' Downloads an item's content to a local file. The service always answers
#' with a **ZIP archive**, whichever kind of item you ask for: a file
#' comes back zipped, and a context or folder comes back as a zip of
#' everything under it. Give `local_path` a `.zip` extension and unpack it
#' with [utils::unzip()].
#'
#' The download is a `POST`, not a `GET` -- the service answers `GET` on
#' this endpoint with `405` and names `POST`/`PUT` as the methods it
#' supports.
#'
#' @param path Repository path of the item to download.
#' @param local_path Local destination path for the ZIP archive.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return `local_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_download("/Acme/Study 1/protocol.sas", "protocol.zip")
#' utils::unzip("protocol.zip", exdir = "protocol")
#' }
#' @export
viya_clinical_download <- function(path, local_path, token = viya_token(),
                                   url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(nzchar(local_path))
  it <- viya_clinical_item(path, token, url)
  .viya_req(h, paste0("/clinicalRepository/repository/items/", it$id,
                      "/content")) |>
    httr2::req_method("POST") |>
    httr2::req_perform() |> httr2::resp_body_raw() |>
    writeBin(local_path)
  message("downloaded ", path, " -> ", local_path, " (zip archive)")
  invisible(local_path)
}

#' List the Clinical Repository's item types
#'
#' The repository's type catalogue: what a `type_id` from
#' [viya_clinical_list()] means, and which types are contexts (containers
#' that carry membership and permissions, e.g. `organization`, `study`)
#' versus files (`sasprogram`, `rprogram`, `sasdataset`, `pdf`, ...).
#' The catalogue is fixed per deployment and returned in one page.
#'
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return A data frame with columns `id`, `name`, `is_context` and
#'   `is_file`.
#' @examples
#' \dontrun{
#' types <- viya_clinical_types()
#' types[types$is_file, ]
#' }
#' @export
viya_clinical_types <- function(token = viya_token(),
                                url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  items <- .viya_clinical_collect(h, "/clinicalRepository/types")
  data.frame(
    id         = vapply(items, function(x) x[["id"]] %||% NA_character_, ""),
    name       = vapply(items, function(x) x[["name"]] %||% NA_character_, ""),
    is_context = vapply(items,
                        function(x) isTRUE(x[["contextType"]]), logical(1)),
    is_file    = vapply(items,
                        function(x) isTRUE(x[["fileType"]]), logical(1)),
    stringsAsFactors = FALSE)
}
