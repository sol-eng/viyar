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

# Mirrors knitr's own eng_sql(): a chunk option given as a bare name (the
# only form YAML `#|` chunk-option syntax allows without `!expr`) is
# looked up as a variable in the knit environment; classic `{sas,
# session=h}` header syntax evaluates `h` itself before the engine ever
# sees it, so an already-resolved handle is accepted as-is too.
.viya_resolve_session <- function(session) {
  if (is.null(session))
    stop("The `sas` engine requires a `session` chunk option naming (or ",
         "providing) a viyar handle, e.g. `#| session: h` (see viya_session()).",
         call. = FALSE)
  h <- if (is.character(session) && length(session) == 1L)
    get(session, envir = knitr::knit_global())
  else session
  if (!inherits(h, "viyar"))
    stop("`session` does not resolve to a viyar handle (see viya_session()).",
         call. = FALSE)
  h
}

# Builds the whole chunk output (code echo + log/listing + raw ODS html)
# as one markdown/HTML string, returned via knitr::asis_output() so it is
# spliced in verbatim regardless of the chunk's own `results` option --
# the formatting decisions here (fencing, raw HTML) are made once, by
# this function, not deferred to knitr's own results-handling rules.
.viya_sas_render <- function(options, code, result) {
  parts <- character(0)
  if (!identical(options$echo, FALSE))
    parts <- c(parts, paste0("```sas\n", code, "\n```"))
  if (!is.null(result$log) && length(result$log))
    parts <- c(parts, paste0("```\n", paste(result$log, collapse = "\n"), "\n```"))
  if (!is.null(result$listing) && length(result$listing))
    parts <- c(parts, paste0("```\n", paste(result$listing, collapse = "\n"), "\n```"))
  if (!is.null(result$html) && length(result$html))
    parts <- c(parts, unname(result$html))
  knitr::asis_output(paste(parts, collapse = "\n\n"))
}

# The knit_engines$set(sas = ...) callback (registered in R/zzz.R). Takes
# the full chunk options list (knitr's own contract for custom engines --
# code lives at options$code, one element per source line) and returns
# the rendered chunk output.
.viya_sas_engine <- function(options) {
  h <- .viya_resolve_session(options$session)
  code <- paste(options$code, collapse = "\n")
  result <- viya_submit_quarto(
    h, code,
    output = options$viya.output %||% "html",
    poll_s = options$viya.poll_s %||% 1,
    timeout_s = options$viya.timeout_s %||% 300,
    error = isTRUE(options$viya.error))
  .viya_sas_render(options, code, result)
}
