#' Submit SAS code and return the log
#'
#' Creates a compute job, polls until it reaches a terminal state, and
#' retrieves the full log.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param code SAS code as a single string (newlines allowed).
#' @param poll_s Polling interval in seconds.
#' @param timeout_s Give up after this many seconds.
#' @return A list with elements `state`, `log` (character vector of log
#'   lines), and `job_id`.
#' @examples
#' \dontrun{
#' r <- viya_submit(h, "proc means data=sashelp.class; run;")
#' cat(r$log, sep = "\n")
#' }
#' @export
viya_submit <- function(h, code, poll_s = 1, timeout_s = 300) {
  stopifnot(inherits(h, "viyar"))
  job <- .viya_req(h, paste0("/compute/sessions/", h$session, "/jobs")) |>
    httr2::req_method("POST") |>
    httr2::req_body_json(list(version = 1,
                              code = as.list(unlist(strsplit(code, "\n"))))) |>
    httr2::req_perform() |> httr2::resp_body_json()
  deadline <- Sys.time() + timeout_s
  state <- "running"
  while (Sys.time() < deadline) {
    state <- .viya_req(h, paste0("/compute/sessions/", h$session,
                                 "/jobs/", job$id, "/state")) |>
      httr2::req_perform() |> httr2::resp_body_string()
    if (state %in% c("completed", "error", "failed", "canceled", "warning"))
      break
    Sys.sleep(poll_s)
  }
  lg <- .viya_req(h, paste0("/compute/sessions/", h$session,
                            "/jobs/", job$id, "/log?limit=100000")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  list(state = state,
       log = vapply(lg$items, function(x) x$line %||% "", ""),
       job_id = job$id)
}

#' List assigned librefs
#'
#' @param h A `viyar` handle from [viya_session()].
#' @return Character vector of libref names.
#' @examples
#' \dontrun{
#' viya_librefs(h)
#' }
#' @export
viya_librefs <- function(h) {
  stopifnot(inherits(h, "viyar"))
  r <- .viya_req(h, paste0("/compute/sessions/", h$session,
                           "/data?limit=100")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  vapply(r$items, `[[`, "", "name")
}

#' List datasets in a libref
#'
#' Uses the Compute data service (fast) and falls back to
#' `dictionary.tables` for libraries the service does not enumerate
#' (e.g. system libraries such as SASHELP).
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param libref Library reference, e.g. `"WORK"`, `"PUBLIC"`, `"SASHELP"`.
#' @return Character vector of member names.
#' @export
viya_datasets <- function(h, libref) {
  stopifnot(inherits(h, "viyar"))
  r <- .viya_req(h, paste0("/compute/sessions/", h$session,
                           "/data/", toupper(libref), "?limit=500")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  nms <- vapply(r$items, `[[`, "", "name")
  if (length(nms)) return(nms)
  viya_members(h, libref)$MEMNAME
}

#' Member detail for a libref via dictionary.tables
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param libref Library reference.
#' @return A data frame with member name, type (`DATA`/`VIEW`) and row
#'   count.
#' @export
viya_members <- function(h, libref) {
  stopifnot(inherits(h, "viyar"), nzchar(libref))
  code <- sprintf(paste0(
    "proc sql;\n  create table WORK._VIYAR_MEMBERS as\n",
    "  select memname, memtype, nobs from dictionary.tables\n",
    "  where libname = '%s';\nquit;"), toupper(libref))
  jr <- viya_submit(h, code)
  if (!identical(jr$state, "completed"))
    warning("dictionary query state: ", jr$state)
  viya_read(h, "WORK", "_VIYAR_MEMBERS")
}
