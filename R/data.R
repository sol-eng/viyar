#' Is a Compute column type numeric?
#'
#' developer.sas.com documents only `CHAR` and `FLOAT` for a Compute
#' column's `type`; the other tokens are matched defensively and are
#' unverified against any deployment.
#'
#' @param type Character vector of column `type` values.
#' @return A logical vector.
#' @noRd
.viya_is_numeric_type <- function(type) {
  grepl("FLOAT|DOUBLE|INT|NUM", toupper(type))
}

#' Read a SAS dataset into an R data.frame
#'
#' Streams rows from the Compute data service in chunks and returns a plain
#' data.frame with numeric SAS columns converted to numeric.
#'
#' Rows are requested with `format=false`, so cells carry the stored values
#' rather than their formatted display text. The endpoint's own default is
#' `format=true`, which returns display strings — a `DATE9.` column would
#' arrive as `"01JAN2020"` and a `DOLLAR12.2` column as `"$1,234.50"`, both
#' of which coerce to `NA`, and a `10.4` column would arrive already
#' rounded to four decimals.
#'
#' The trade-off is that a SAS date arrives as its stored number: days
#' since 1960-01-01. Name those columns in `dates` to get R `Date`s back.
#' This is not automatic because the Compute `columns` endpoint reports
#' only a format's `decimals` and `length`, never its name, so there is
#' nothing in the response that identifies a column as a date.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param libref Library reference, e.g. `"PUBLIC"`.
#' @param table Dataset name, e.g. `"HEART"`.
#' @param dates Character vector of numeric columns holding SAS dates, to
#'   convert to `Date`. Matched against the table's column names
#'   case-insensitively; a name that is absent, or that belongs to a
#'   character column, is an error rather than a silent no-op.
#' @param max_rows Cap on rows read (a message is emitted if hit).
#' @param chunk Rows per request page.
#' @return A plain data.frame.
#' @examples
#' \dontrun{
#' heart <- viya_read(h, "PUBLIC", "HEART")
#' adsl  <- viya_read(h, "WORK", "ADSL", dates = c("TRTSDT", "TRTEDT"))
#' }
#' @export
viya_read <- function(h, libref, table, dates = NULL, max_rows = 100000,
                      chunk = 5000) {
  stopifnot(inherits(h, "viyar"))
  if (!is.null(dates) && !is.character(dates))
    stop("`dates` must be a character vector of column names")
  base <- paste0("/compute/sessions/", h$session, "/data/",
                 toupper(libref), "/", toupper(table))
  cols <- .viya_req(h, paste0(base, "/columns?limit=1000")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  col_names <- vapply(cols$items, `[[`, "", "name")
  col_types <- vapply(cols$items, function(x) x$type %||% "", "")

  # Resolved before any row is fetched, so a typo costs one request
  # rather than a full table read.
  date_idx <- integer(0)
  if (length(dates)) {
    date_idx <- match(toupper(dates), toupper(col_names))
    if (anyNA(date_idx))
      stop("`dates` column not found in ", toupper(libref), ".",
           toupper(table), ": ",
           paste(dates[is.na(date_idx)], collapse = ", "))
    bad <- !.viya_is_numeric_type(col_types[date_idx])
    if (any(bad))
      stop("`dates` column is not numeric: ",
           paste(dates[bad], collapse = ", "))
  }

  rows <- list(); got <- 0
  repeat {
    r <- .viya_req(h, sprintf("%s/rows?format=false&start=%d&limit=%d",
                              base, got, min(chunk, max_rows - got))) |>
      httr2::req_perform() |> httr2::resp_body_json()
    if (!length(r$items)) break
    rows <- c(rows, lapply(r$items, `[[`, "cells"))
    got <- got + length(r$items)
    if (got >= max_rows) { message("capped at ", max_rows, " rows"); break }
    if (length(r$items) < chunk) break
  }
  if (!length(rows)) {
    empty <- lapply(col_types, function(ty)
      if (.viya_is_numeric_type(ty)) numeric(0) else character(0))
    empty[date_idx] <- list(as.Date(character(0)))
    return(stats::setNames(as.data.frame(empty), col_names))
  }

  df <- as.data.frame(do.call(rbind, lapply(rows, function(cells)
    lapply(cells, function(v) if (is.null(v)) NA else v))),
    stringsAsFactors = FALSE)
  names(df) <- col_names
  df[] <- lapply(seq_along(df), function(i) {
    v <- unlist(df[[i]], use.names = FALSE)
    if (.viya_is_numeric_type(col_types[i]))
      suppressWarnings(as.numeric(v))
    else trimws(as.character(v))
  })
  # SAS's date epoch, not R's.
  df[date_idx] <- lapply(df[date_idx], as.Date, origin = "1960-01-01")
  message("read ", nrow(df), " x ", ncol(df), " from ",
          toupper(libref), ".", toupper(table))
  df
}

#' Write an R data.frame to a SAS dataset
#'
#' Stages the data as CSV through the Viya Files service and imports it in
#' the compute session using `FILENAME FILESRVC` + `PROC IMPORT`.
#'
#' The staging file lands in the caller's own private `"@myFolder"` by
#' default (a Viya Folders API well-known delegate -- SAS's own
#' documentation describes it as "not visible to other users except
#' administrative users"), not the shared `/Public` folder every other
#' user of the deployment can see and write to. The SAS-side `FILENAME
#' FILESRVC` reference doesn't need `staging_folder`'s path at all: it
#' addresses the uploaded file directly by its own resource URI
#' (`FILESRVC '/files/files/<uuid>'`, FILESRVC's "Form 1" per SAS's
#' Global Statements Reference), which is also more robust than the
#' folder-path/name-matching alternative used by the previous
#' `/Public`-based design.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param df The data.frame to write.
#' @param libref Target library reference, e.g. `"WORK"`.
#' @param table Target dataset name.
#' @param staging_folder Viya folder used for the temporary CSV -- a real
#'   path (e.g. `"/Public"`) or a well-known delegate like `"@myFolder"`
#'   or `"@public"`.
#' @param cleanup Delete the staged CSV afterwards.
#' @return The [viya_submit()] result of the import job, invisibly.
#' @examples
#' \dontrun{
#' viya_write(h, mtcars, "WORK", "MTCARS")
#' }
#' @export
viya_write <- function(h, df, libref, table, staging_folder = "@myFolder",
                       cleanup = TRUE) {
  stopifnot(inherits(h, "viyar"), is.data.frame(df))
  # write.csv() would otherwise emit logical columns as literal "TRUE"/
  # "FALSE" text, which PROC IMPORT's guessing reads as a SAS character
  # variable -- confirmed live -- losing boolean-ness entirely (and, per
  # saspy's own equivalent logic in sasiohttp.py, that's the same
  # 0/1-not-text convention it uses for a clean bool column too, though
  # saspy's check only holds for a column pandas has kept as native bool
  # dtype -- one with a missing value gets silently upcast to generic
  # object dtype first, falling through to its string handling instead).
  # R's `logical` has no such split: it holds NA natively without ever
  # changing type, so converting to integer here handles every case
  # uniformly, missing values included.
  df[] <- lapply(df, function(col) if (is.logical(col)) as.integer(col) else col)
  tmp   <- tempfile(fileext = ".csv")
  fname <- paste0("viyar_stage_", format(Sys.time(), "%H%M%S"), ".csv")
  utils::write.csv(df, tmp, row.names = FALSE, na = "")
  up <- viya_upload(h, tmp, staging_folder, name = fname)
  unlink(tmp)

  code <- sprintf(paste0(
    "filename _viyar filesrvc '/files/files/%s';\n",
    "proc import datafile=_viyar out=%s.%s dbms=csv replace;\n",
    "  getnames=yes; guessingrows=max;\nrun;\nfilename _viyar clear;"),
    up$id, toupper(libref), toupper(table))
  r <- viya_submit(h, code)

  if (cleanup && !is.null(up$id)) {
    tryCatch(.viya_req(h, paste0("/files/files/", up$id)) |>
               httr2::req_method("DELETE") |> httr2::req_perform(),
             error = function(e) message("staging cleanup failed: ",
                                         conditionMessage(e)))
  }
  if (!identical(r$state, "completed"))
    warning("PROC IMPORT state: ", r$state, " - check the log")
  message("wrote ", nrow(df), " rows -> ", toupper(libref), ".",
          toupper(table), " (", r$state, ")")
  invisible(r)
}
