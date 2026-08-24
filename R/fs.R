.viya_fs_escape <- function(path) {
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  paste(segments, collapse = "~fs~")
}

.viya_fs_exists <- function(h, path) {
  tryCatch({
    .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                        .viya_fs_escape(path))) |>
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
#'   `"/gel/homes/samiul/reports/2026"`. A relative path is resolved
#'   against the session's current working directory.
#' @return `path`, invisibly.
#' @examples
#' \dontrun{
#' viya_fs_mkdir(h, "/gel/homes/samiul/reports/2026")
#' }
#' @export
viya_fs_mkdir <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(path))
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  if (!length(segments)) stop("path must have at least one segment")

  for (i in seq_along(segments)) {
    partial <- paste(segments[seq_len(i)], collapse = "/")
    if (!.viya_fs_exists(h, partial)) {
      parent <- if (i == 1) "." else paste(segments[seq_len(i - 1)], collapse = "/")
      .viya_req(h, paste0("/compute/sessions/", h$session, "/files/",
                          .viya_fs_escape(parent))) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(name = segments[i], isDirectory = TRUE)) |>
        httr2::req_perform()
      message("created directory ", partial)
    }
  }
  invisible(path)
}
