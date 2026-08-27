.viya_fs_escape <- function(path) {
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  prefix <- if (startsWith(path, "/")) "~fs~" else ""
  utils::URLencode(paste0(prefix, paste(segments, collapse = "~fs~")), reserved = TRUE)
}

.viya_fs_exists <- function(h, path) {
  tryCatch({
    .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                        .viya_fs_escape(path))) |>
      httr2::req_options(path_as_is = TRUE) |>
      httr2::req_perform()
    TRUE
  }, error = function(e) FALSE)
}

#' Create a directory on a compute session's filesystem
#'
#' Unlike [viya_create_folder()] (SAS Content), this creates a real
#' directory on the OS filesystem the compute session sees -- a home
#' directory, an NFS-mounted shared path, or any path the session process
#' can write to. Creates every missing intermediate directory along
#' `path`, one level at a time (there is no server-side recursive
#' create). Already-existing segments are left untouched (safe to call
#' repeatedly).
#'
#' @param h A `viyar` handle from [viya_session()] (must have an active
#'   compute session -- this operates on that session's filesystem).
#' @param path Directory path to create, e.g.
#'   `"/nfs/homes/user/reports/2026"`. A relative path is resolved
#'   against the session's current working directory.
#' @return `path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_mkdir(h, "/nfs/homes/user/reports/2026")
#' }
#' @export
viya_fs_mkdir <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(h$session %||% ""), nzchar(path))
  is_absolute <- startsWith(path, "/")
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  if (!length(segments)) stop("path must have at least one segment")

  for (i in seq_along(segments)) {
    partial <- paste(segments[seq_len(i)], collapse = "/")
    if (is_absolute) partial <- paste0("/", partial)
    if (!.viya_fs_exists(h, partial)) {
      if (i == 1) {
        parent <- if (is_absolute) "/" else "."
      } else {
        parent <- paste(segments[seq_len(i - 1)], collapse = "/")
        if (is_absolute) parent <- paste0("/", parent)
      }
      .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                          .viya_fs_escape(parent))) |>
        httr2::req_options(path_as_is = TRUE) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(name = segments[i], isDirectory = TRUE)) |>
        httr2::req_perform()
      message("created directory ", partial)
    }
  }
  invisible(path)
}

#' Upload a local file to a compute session's filesystem
#'
#' Unlike [viya_upload()] (which uploads to SAS Content), this writes
#' directly to the OS filesystem the compute session sees.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param local_path Path of the local file.
#' @param remote_path Destination path on the session's filesystem, e.g.
#'   `"/nfs/homes/user/report.csv"`.
#' @return `remote_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_upload(h, "report.html", "/nfs/homes/user/report.html")
#' }
#' @export
viya_fs_upload <- function(h, local_path, remote_path) {
  stopifnot(inherits(h, "viyar"), nzchar(h$session %||% ""), file.exists(local_path), nzchar(remote_path))
  .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                      .viya_fs_escape(remote_path), "/content")) |>
    httr2::req_options(path_as_is = TRUE) |>
    httr2::req_method("PUT") |>
    httr2::req_headers(`Content-Type` = "application/octet-stream") |>
    httr2::req_body_file(local_path) |>
    httr2::req_perform()
  message("uploaded '", local_path, "' -> ", remote_path)
  invisible(remote_path)
}

#' Download a file from a compute session's filesystem
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param remote_path Path on the session's filesystem, e.g.
#'   `"/nfs/homes/user/report.csv"`.
#' @param local_path Local destination path.
#' @return `local_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_download(h, "/nfs/homes/user/report.csv", "report.csv")
#' }
#' @export
viya_fs_download <- function(h, remote_path, local_path) {
  stopifnot(inherits(h, "viyar"), nzchar(h$session %||% ""), nzchar(remote_path))
  .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                      .viya_fs_escape(remote_path), "/content")) |>
    httr2::req_options(path_as_is = TRUE) |>
    httr2::req_perform() |> httr2::resp_body_raw() |>
    writeBin(local_path)
  message("downloaded ", remote_path, " -> ", local_path)
  invisible(local_path)
}

#' Delete a file or directory from a compute session's filesystem
#'
#' Works identically for a single file and a non-empty directory --
#' confirmed live, no separate recursive flag needed. The File System
#' service requires an `If-Match` header carrying the resource's current
#' `ETag` (omitting it returns `428 Precondition Required`), so this
#' first does a `GET` to read the `ETag`, then sends the `DELETE` with
#' that value.
#'
#' @param h A `viyar` handle from [viya_session()] (must have an active
#'   compute session).
#' @param path File or directory path to delete, e.g.
#'   `"/nfs/homes/user/reports/2026"`. A relative path is resolved
#'   against the session's current working directory.
#' @return `path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_delete(h, "/nfs/homes/user/reports/2026")
#' }
#' @export
viya_fs_delete <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(h$session %||% ""), nzchar(path))
  req <- .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                             .viya_fs_escape(path))) |>
    httr2::req_options(path_as_is = TRUE)
  etag <- req |> httr2::req_perform() |> httr2::resp_header("etag")
  req |>
    httr2::req_method("DELETE") |>
    httr2::req_headers(`If-Match` = etag) |>
    httr2::req_perform()
  message("deleted ", path)
  invisible(path)
}

#' List a directory's contents on a compute session's filesystem
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param path Directory path on the session's filesystem. Pass `"."` to
#'   list the session's current working directory.
#' @return A data frame with columns `name`, `isDirectory`, `size`, `path`.
#' @examples
#' \dontrun{
#' viya_fs_list(h, "/nfs/homes/user")
#' viya_fs_list(h, ".")  # what's in the session's working directory
#' }
#' @export
viya_fs_list <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(h$session %||% ""), nzchar(path))
  r <- .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                           .viya_fs_escape(path), "/members?limit=500")) |>
    httr2::req_options(path_as_is = TRUE) |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(
    name = vapply(r$items, `[[`, "", "name"),
    isDirectory = vapply(r$items, `[[`, logical(1), "isDirectory"),
    size = vapply(r$items, function(x) x[["size"]] %||% NA_real_, numeric(1)),
    path = vapply(r$items, `[[`, "", "path"))
}
