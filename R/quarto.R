#' Submit SAS code inside a Quarto/knitr chunk, failing fast on error
#'
#' The engine-facing counterpart to [viya_submit()]: same submit-and-poll
#' behavior, but tuned for a rendered document rather than an interactive
#' call. The log is always fetched internally (regardless of `output`) so
#' a failure can be diagnosed from the error message alone; it is dropped
#' from the returned list again unless `"log"` was one of the kinds you
#' asked for, or the job didn't complete.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param code SAS code as a single string (newlines allowed).
#' @param output Which output kinds to retrieve: any of `"log"`,
#'   `"listing"`, `"html"`. Defaults to `"html"` -- unlike [viya_submit()]
#'   itself (which defaults to `"log"`), since this function is meant for
#'   rendering a report-style document, not console debugging.
#' @param poll_s Polling interval in seconds.
#' @param timeout_s Give up after this many seconds.
#' @param error If `FALSE` (the default), a job state other than
#'   `"completed"` raises an R error (including the last few log lines),
#'   stopping the render. Set `TRUE` to suppress the error and return the
#'   result as-is instead, e.g. for a chunk where a non-`"completed"`
#'   state is expected or acceptable.
#' @return A list shaped like [viya_submit()]'s own return value.
#' @examples
#' \dontrun{
#' h <- viya_session()
#' r <- viya_submit_quarto(h, "ods html5; proc means data=sashelp.class; run;")
#' r$html[[1]]
#' }
#' @export
viya_submit_quarto <- function(h, code, output = "html", poll_s = 1,
                               timeout_s = 300, error = FALSE) {
  stopifnot(inherits(h, "viyar"))
  output <- match.arg(output, c("log", "listing", "html"), several.ok = TRUE)
  r <- viya_submit(h, code, poll_s = poll_s, timeout_s = timeout_s,
                   output = union(output, "log"))
  failed <- !identical(r$state, "completed")
  if (failed && !error) {
    tail_lines <- utils::tail(r$log, 5)
    stop("SAS job did not complete (state: \"", r$state, "\")",
         if (length(tail_lines)) paste0(":\n", paste(tail_lines, collapse = "\n")) else "",
         call. = FALSE)
  }
  if (!("log" %in% output) && !failed) r$log <- NULL
  r
}
