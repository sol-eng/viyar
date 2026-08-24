.viya_folder <- function(h, folder_path) {
  .viya_req(h, paste0("/folders/folders/@item?path=",
                      utils::URLencode(folder_path, reserved = TRUE))) |>
    httr2::req_perform() |> httr2::resp_body_json()
}

#' Upload a local file to a Viya folder
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param local_path Path of the local file.
#' @param folder_path Viya folder path, e.g. `"/Public"`.
#' @param name Name to store the file under (defaults to the local
#'   basename).
#' @return The Files service response, invisibly (contains the file `id`).
#' @examples
#' \dontrun{
#' viya_upload(h, "report.html", "/Public")
#' }
#' @export
viya_upload <- function(h, local_path, folder_path,
                        name = basename(local_path)) {
  stopifnot(inherits(h, "viyar"), file.exists(local_path))
  fld <- .viya_folder(h, folder_path)
  res <- .viya_req(h, paste0("/files/files?parentFolderUri=/folders/folders/",
                             fld$id)) |>
    httr2::req_method("POST") |>
    httr2::req_headers("Content-Disposition" =
                         sprintf('attachment; filename="%s"', name)) |>
    httr2::req_body_file(local_path) |>
    httr2::req_perform() |> httr2::resp_body_json()
  message("uploaded '", name, "' -> ", folder_path)
  invisible(res)
}

#' Download a file from a Viya folder
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param viya_path Full Viya path of the file, e.g.
#'   `"/Public/report.html"`.
#' @param local_path Local destination path.
#' @return `local_path`, invisibly.
#' @examples
#' \dontrun{
#' viya_download(h, "/Public/report.html", "copy.html")
#' }
#' @export
viya_download <- function(h, viya_path, local_path) {
  stopifnot(inherits(h, "viyar"))
  fld <- .viya_folder(h, dirname(viya_path))
  fname <- basename(viya_path)
  mem <- .viya_req(h, paste0("/folders/folders/", fld$id,
                             "/members?limit=500")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  hit <- Filter(function(m) identical(m$name, fname), mem$items)
  if (!length(hit)) stop("'", fname, "' not found in ", dirname(viya_path))
  .viya_req(h, paste0(hit[[1]]$uri, "/content")) |>
    httr2::req_perform() |> httr2::resp_body_raw() |>
    writeBin(local_path)
  message("downloaded ", viya_path, " -> ", local_path)
  invisible(local_path)
}

.viya_folder_or_null <- function(h, folder_path) {
  tryCatch(.viya_folder(h, folder_path), error = function(e) NULL)
}

#' Create a folder in SAS Content (the Files/Folders service)
#'
#' Creates every missing folder along `path`, one level at a time -- the
#' Folders API has no recursive/nested create, so e.g.
#' `viya_create_folder(h, "/Public/Reports/2026")` creates `Reports`
#' under `/Public` first if it's missing, then `2026` under that.
#' Already-existing segments are left untouched (safe to call repeatedly).
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param path Full Viya folder path to create, e.g. `"/Public/Reports"`.
#' @return The final (leaf) folder's resource info, invisibly.
#' @examples
#' \dontrun{
#' viya_create_folder(h, "/Public/Reports/2026")
#' }
#' @export
viya_create_folder <- function(h, path) {
  stopifnot(inherits(h, "viyar"), nzchar(path))
  segments <- strsplit(path, "/")[[1]]
  segments <- segments[nzchar(segments)]
  if (!length(segments)) stop("path must have at least one segment")

  parent_id <- NULL
  fld <- NULL
  for (i in seq_along(segments)) {
    partial <- paste0("/", paste(segments[seq_len(i)], collapse = "/"))
    fld <- .viya_folder_or_null(h, partial)
    if (is.null(fld)) {
      parent_uri <- if (is.null(parent_id)) "none"
                    else paste0("/folders/folders/", parent_id)
      fld <- .viya_req(h, paste0("/folders/folders?parentFolderUri=",
                                 utils::URLencode(parent_uri, reserved = TRUE))) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(name = segments[i])) |>
        httr2::req_perform() |> httr2::resp_body_json()
      message("created folder ", partial)
    }
    parent_id <- fld$id
  }
  invisible(fld)
}
