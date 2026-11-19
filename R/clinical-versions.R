# Version history and bulk download for the Clinical Repository. Read-only,
# built on the same helpers as R/clinical.R. All request shapes below were
# confirmed live against a Clinical Acceleration cluster.

#' List a Clinical Repository file's versions
#'
#' Returns the version history of one file, newest first. A file only
#' accumulates versions once versioning is on for it; an unversioned file
#' has a single row whose `file_version` is `"-"`.
#'
#' @param path Repository path of the file.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return A data frame with columns `version` (an integer counter),
#'   `file_version` (the label, e.g. `"1.0"`; pass this to
#'   [viya_clinical_download_version()]), `comment` (`NA` when none),
#'   `created_by`, `created` (`POSIXct`), `size` (bytes), `signed` and
#'   `latest`.
#' @examples
#' \dontrun{
#' viya_clinical_versions("/Acme/Study 1/data/adam/adsl.xpt")
#' }
#' @export
viya_clinical_versions <- function(path, token = viya_token(),
                                   url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  it <- viya_clinical_item(path, token, url)
  items <- .viya_clinical_collect(
    h, paste0("/clinicalRepository/repository/items/", it$id,
              "/versions?limit=100"))
  chr <- function(field)
    vapply(items, function(x) x[[field]] %||% NA_character_, "")
  data.frame(
    version      = vapply(items, function(x) as.integer(x[["version"]] %||% NA),
                          integer(1)),
    file_version = chr("fileVersion"),
    comment      = chr("comment"),
    created_by   = chr("createdBy"),
    created      = as.POSIXct(chr("creationTimeStamp"),
                              format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"),
    size         = vapply(items, function(x) as.numeric(x[["size"]] %||% NA),
                          numeric(1)),
    signed       = vapply(items, function(x) isTRUE(x[["signed"]]), logical(1)),
    latest       = vapply(items, function(x) isTRUE(x[["latest"]]), logical(1)),
    stringsAsFactors = FALSE
  )
}

#' Download one version of a Clinical Repository file
#'
#' Downloads the content a file had at a given version, byte for byte.
#' [viya_clinical_download()] only ever gives you the latest content.
#'
#' @param path Repository path of the file.
#' @param version The version's `file_version` label from
#'   [viya_clinical_versions()], as a string such as `"1.0"`. The integer
#'   `version` column does not work: the service answers `404` for it.
#' @param local_path Local destination file.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return `local_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_clinical_versions("/Acme/Study 1/adsl.xpt")
#' viya_clinical_download_version("/Acme/Study 1/adsl.xpt", "1.0",
#'                                "adsl_v1.xpt")
#' }
#' @export
viya_clinical_download_version <- function(path, version, local_path,
                                           token = viya_token(),
                                           url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(is.character(version), length(version) == 1, nzchar(version),
            is.character(local_path), length(local_path) == 1,
            nzchar(local_path))
  it <- viya_clinical_item(path, token, url)
  have <- viya_clinical_versions(path, token, url)$file_version
  if (!version %in% have)
    stop("'", path, "' has no version '", version, "'. Available: ",
         paste0("'", have, "'", collapse = ", "), ". Use the `file_version` ",
         "value from viya_clinical_versions().")
  resp <- .viya_req(h, paste0("/clinicalRepository/repository/items/", it$id,
                              "/versions/", utils::URLencode(version, reserved = TRUE),
                              "/content")) |>
    httr2::req_perform()
  writeBin(httr2::resp_body_raw(resp), local_path)
  message("downloaded ", path, " version ", version, " -> ", local_path)
  invisible(local_path)
}

#' Download every file matching a search as one ZIP
#'
#' Fetches all files matching an RQL filter, or a full-text search, in one
#' request and writes them as a ZIP archive. Unlike [viya_clinical_download()]
#' on a folder, the match can span the whole repository. The archive stores
#' files flat, by file name alone, so two matches that share a name from
#' different folders are not told apart by path.
#'
#' @param filter An RQL filter, as for [viya_clinical_find()], e.g.
#'   `"eq(name,'adsl.xpt')"` or
#'   `"eq(location,'/Acme/Study 1/data/adam')"`. Supports `and`/`or`/`not`;
#'   the `in()` function is rejected by the service.
#' @param local_path Local destination for the ZIP archive.
#' @param text A full-text search string, instead of `filter`. This is not
#'   a file-name match: live, `"adsl"` returned a different file than
#'   `adsl.xpt`. Use `filter` to select by name.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return `local_path`, invisibly -- or `NULL`, with a warning and no file
#'   written, when nothing matched.
#' @examples
#' \dontrun{
#' viya_clinical_download_many("eq(location,'/Acme/Study 1/data/adam')",
#'                             "adam.zip")
#' utils::unzip("adam.zip", exdir = "adam")
#' }
#' @export
viya_clinical_download_many <- function(filter = NULL, local_path, text = NULL,
                                        token = viya_token(),
                                        url = viya_config()$url) {
  h <- .viya_clinical_h(token, url)
  stopifnot(is.character(local_path), length(local_path) == 1,
            nzchar(local_path))
  if (is.null(filter) && is.null(text))
    stop("give a `filter` (an RQL expression) or `text` to search for")
  if (!is.null(filter) && !is.null(text))
    stop("give either `filter` or `text`, not both")
  body <- if (!is.null(filter)) list(filter = filter) else list(text = text)
  stopifnot(nzchar(unlist(body)))
  resp <- .viya_req(h, "/clinicalRepository/repository/files/content") |>
    httr2::req_method("POST") |> httr2::req_body_json(body) |>
    httr2::req_perform()
  # Found live: a search that matches nothing is a 200 with an empty body.
  if (!httr2::resp_has_body(resp)) {
    warning("nothing matched, so no archive was written")
    return(invisible(NULL))
  }
  writeBin(httr2::resp_body_raw(resp), local_path)
  message("downloaded matching files -> ", local_path, " (zip archive)")
  invisible(local_path)
}
