#' Submit SAS code and return its output
#'
#' Creates a compute job, polls until it reaches a terminal state, and
#' retrieves the output kinds named in `output`.
#'
#' Each kind costs one or more extra requests, so only the ones you ask
#' for are fetched and only those appear in the result. The default,
#' `"log"`, matches what earlier versions always returned.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param code SAS code as a single string (newlines allowed).
#' @param poll_s Polling interval in seconds.
#' @param timeout_s Give up after this many seconds.
#' @param output Which output kinds to retrieve: any of `"log"`,
#'   `"listing"` (traditional LST text) and `"html"` (ODS output).
#'   Defaults to `"log"`.
#'
#'   `viyar` does not add ODS statements to your code, so a destination
#'   produces output only when your own code opens it. A compute server
#'   starts with `ods listing` closed, so `$listing` is empty until you
#'   write `ods listing;` yourself (see the second example).
#' @return A list with element `state`, then one element per requested
#'   output kind — `log` and `listing` are character vectors of lines,
#'   `html` is a character vector of HTML documents named by ODS output
#'   object — and finally `job_id`.
#' @examples
#' \dontrun{
#' r <- viya_submit(h, "proc means data=sashelp.class; run;")
#' cat(r$log, sep = "\n")
#'
#' r <- viya_submit(h, "ods listing;
#'                      proc print data=sashelp.class(obs=5); run;
#'                      ods listing close;",
#'                  output = c("log", "listing"))
#' cat(r$listing, sep = "\n")
#'
#' r <- viya_submit(h, "proc means data=sashelp.class; run;",
#'                  output = "html")
#' writeLines(r$html[[1]], "means.html")
#' }
#' @export
viya_submit <- function(h, code, poll_s = 1, timeout_s = 300,
                        output = c("log")) {
  stopifnot(inherits(h, "viyar"))
  output <- match.arg(output, c("log", "listing", "html"), several.ok = TRUE)
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
  out <- list(state = state)
  if ("log" %in% output)
    out$log <- .viya_job_lines(h, job$id, "log")
  if ("listing" %in% output)
    out$listing <- .viya_job_lines(h, job$id, "listing")
  if ("html" %in% output)
    out$html <- .viya_job_html(h, job$id)
  out$job_id <- job$id
  out
}

# The log and listing endpoints return the same collection shape:
# items[] each carrying a `line` (and a `type` we don't filter on).
.viya_job_lines <- function(h, job_id, what) {
  r <- .viya_req(h, paste0("/compute/sessions/", h$session, "/jobs/", job_id,
                           "/", what, "?limit=100000")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  vapply(r$items, function(x) x$line %||% "", "")
}

# The results collection mixes ODS output with TABLE entries describing
# datasets the job created; only the former has HTML to download, and each
# item's content sits behind its own link rather than in the collection.
.viya_job_html <- function(h, job_id) {
  r <- .viya_req(h, paste0("/compute/sessions/", h$session, "/jobs/", job_id,
                           "/results?limit=1000")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  ods <- Filter(function(x) identical(x$type, "ODS"), r$items)
  if (!length(ods)) return(character())
  html <- vapply(ods, function(x) {
    .viya_req(h, .viya_result_path(h, x$links)) |>
      httr2::req_perform() |> httr2::resp_body_string()
  }, "")
  names(html) <- vapply(ods, function(x) x$name %||% x$id %||% "", "")
  html
}

# Prefers an explicit `content` relation, falling back to `self` (which is
# what the service returns for a result whose content is the resource
# itself). Hrefs come back as paths, but strip the base URL if a deployment
# ever returns an absolute one -- `.viya_req()` prepends it either way.
.viya_result_path <- function(h, links) {
  rels <- vapply(links, function(l) l$rel %||% "", "")
  i <- match("content", rels)
  if (is.na(i)) i <- match("self", rels)
  if (is.na(i)) i <- 1L
  href <- links[[i]]$href %||% ""
  if (!nzchar(href)) stop("compute result has no downloadable link")
  if (startsWith(href, h$base)) substring(href, nchar(h$base) + 1L) else href
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
  viya_members(h, libref)$memname
}

#' Member detail for a libref via dictionary.tables
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param libref Library reference.
#' @return A data frame with columns `memname`, `memtype` (`DATA`/`VIEW`),
#'   and `nobs` (row count) — lowercase, matching the exact case of the
#'   `PROC SQL` `SELECT` list that creates the underlying table (SAS
#'   preserves the case a variable is defined with; it does not
#'   uppercase it).
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
  mem <- suppressMessages(viya_read(h, "WORK", "_VIYAR_MEMBERS"))
  message("read ", nrow(mem), " member", if (nrow(mem) != 1) "s" else "",
          " of ", toupper(libref))
  mem
}
