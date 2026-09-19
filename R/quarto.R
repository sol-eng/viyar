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
  h <- if (is.character(session) && length(session) == 1L) {
    if (!exists(session, envir = knitr::knit_global()))
      stop("`session: ", session, "` does not name any object in the knit ",
           "environment -- did the setup chunk run viya_session()?", call. = FALSE)
    get(session, envir = knitr::knit_global())
  } else session
  if (!inherits(h, "viyar"))
    stop("`session` does not resolve to a viyar handle (see viya_session()).",
         call. = FALSE)
  h
}

# ODS HTML5 output is a complete standalone document, with its own
# <head><style> block -- SAS's default template centers title/heading
# elements via broad, unscoped selectors. Splicing that verbatim into a
# Quarto page lets its <style> block leak into the surrounding page (any
# <style> tag found anywhere in a parsed HTML document applies page-wide),
# overriding Quarto's own section-heading alignment. An iframe's srcdoc
# gives the ODS document its own DOM, scoping its CSS to itself; the
# onload handler grows the iframe to fit its content instead of clipping
# it at a guessed fixed height.
#
# The asis_output() text this feeds into is parsed as CommonMark before it
# ever reaches a browser -- pandoc's raw-HTML-block rule ends a block at
# the first blank line, even one sitting inside a quoted attribute value
# where an actual HTML parser wouldn't care. Real ODS output is blank-line
# -heavy, so a raw newline left in the srcdoc value truncates the <iframe>
# block partway through and spills the rest of the ODS document into the
# surrounding page as loose HTML -- the exact leak this function exists to
# prevent. Encoding newlines keeps the whole tag on one physical line, so
# pandoc can never see a blank line inside it.
.viya_html_iframe <- function(html) {
  escaped <- gsub("&", "&amp;", html, fixed = TRUE)
  escaped <- gsub('"', "&quot;", escaped, fixed = TRUE)
  escaped <- gsub("\r\n|\r|\n", "&#10;", escaped)
  paste0(
    '<iframe srcdoc="', escaped, '" ',
    'style="width:100%; border:none;" ',
    'onload="this.style.height=this.contentWindow.document.documentElement.scrollHeight+\'px\';">',
    '</iframe>')
}

# Keyword/statement/procedure lists drawn directly from SAS's own reference
# documentation (documentation.sas.com): SAS 9.4 Global Statements:
# Reference; SAS 9.4 DATA Step Statements: Reference; SAS 9.4 Output
# Delivery System: User's Guide (ODS statements/destinations); SAS Viya
# Foundation Procedures; Base SAS 9.4 Procedures Guide, Seventh Edition;
# Base SAS 9.4 Procedures Guide: Statistical Procedures; SAS 9.4 SQL
# Procedure User's Guide -- not guessed. This is a lexical highlighter, not
# a parser: tokens are recognized by identity, not grammatical position (a
# variable coincidentally named `sort` would be colored like the SORT
# procedure). The documented global statement `X` (shells out to the OS)
# is deliberately left out for the same reason: a single-letter keyword
# would highlight nearly every one-character variable name in ordinary
# code.
.viya_sas_keywords <- c(
  "DATA", "RUN", "QUIT", "PROC", "LIBNAME", "FILENAME", "OPTIONS", "TITLE",
  "FOOTNOTE", "ENDSAS", "CATNAME", "DM", "LOCK", "LOCKDOWN", "MISSING",
  "PAGE", "RESETLINE", "SASFILE", "SKIP", "SYSECHO",
  "ARRAY", "ATTRIB", "BY", "CALL", "CARDS", "CARDS4", "DATALINES",
  "DATALINES4", "DELETE", "DESCRIBE", "DISPLAY", "DROP", "ERROR", "EXECUTE",
  "FILE", "FORMAT", "INFILE", "INFORMAT", "INPUT", "KEEP", "LABEL",
  "LENGTH", "LIST", "LOSTCARD", "MERGE", "MODIFY", "OUTPUT", "PUT",
  "PUTLOG", "REDIRECT", "REMOVE", "RENAME", "REPLACE", "RETAIN", "SET",
  "UPDATE", "WHERE", "WINDOW",
  "ODS", "CLOSE", "EXCLUDE", "TRACE", "RESULTS", "SHOW", "VERIFY",
  "USEGOPT", "PATH", "PREFERENCES", "GRAPHICS", "ESCAPECHAR", "PROCLABEL",
  "PROCTITLE", "PACKAGE")

.viya_sas_control_flow <- c(
  "IF", "THEN", "ELSE", "DO", "END", "WHEN", "OTHERWISE", "SELECT", "GOTO",
  "LINK", "RETURN", "STOP", "ABORT", "CONTINUE", "LEAVE")

.viya_sas_procs <- c(
  "MEANS", "PRINT", "SORT", "SQL", "FREQ", "UNIVARIATE", "CORR", "REPORT",
  "SUMMARY", "TABULATE", "TRANSPOSE", "APPEND", "CONTENTS", "COPY", "CPORT",
  "CIMPORT", "DATASETS", "EXPORT", "IMPORT", "FCMP", "FONTREG", "HADOOP",
  "HDMD", "HTTP", "JSON", "LUA", "MIGRATE", "PRINTTO", "PROTO", "PWENCODE",
  "QDEVICE", "SOAP", "SQOOP", "STREAM", "XSL", "AUTHLIB", "DS2", "DSTODS2",
  "FEDSQL", "S3", "SCOREACCEL", "CASUTIL",
  "HTML", "HTML5", "HTML3", "LISTING", "PDF", "RTF", "EXCEL", "POWERPOINT",
  "EPUB", "EPUB2", "EPUB3", "PCL", "PS", "PHTML", "CHTML", "CSVALL",
  "MARKUP", "PRINTER", "DOCUMENT")

.viya_html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub('"', "&quot;", x, fixed = TRUE)
}

# Tokenizes SAS source and wraps each token in the pandoc-standard
# highlighting span classes (kw/cf/ot/co/st/va/fu/dv) that Quarto's HTML
# theme already themes generically via plain `code span.kw { color: ... }`
# rules -- not scoped to a specific language. Reusing those gives real,
# colored highlighting without a Kate or TextMate syntax file and without
# a document-level `syntax-definitions` YAML entry, which SAS has neither
# of in pandoc/skylighting (VS Code/Positron's own SAS extension is a
# TextMate grammar, a different, incompatible format skylighting can't
# load). Newlines are encoded as `&#10;` for the same reason as
# .viya_html_iframe(): this text is parsed as CommonMark before a browser
# ever sees it, and pandoc's raw-HTML-block rule ends a block at the first
# blank line -- real SAS code routinely has blank lines between steps.
.viya_sas_highlight <- function(code) {
  kw <- paste0("(?i:\\b(?:", paste(.viya_sas_keywords, collapse = "|"), ")\\b)")
  cf <- paste0("(?i:\\b(?:", paste(.viya_sas_control_flow, collapse = "|"), ")\\b)")
  ot <- paste0("(?i:\\b(?:", paste(.viya_sas_procs, collapse = "|"), ")\\b)")

  pattern <- paste(
    "(?s:/\\*.*?\\*/)",        # block comment
    "(?ms:^[ \\t]*\\*.*?;)",   # line comment (a `* ... ;` statement)
    '"(?:[^"]|"")*"',          # double-quoted string ("" is an escaped quote)
    "'(?:[^']|'')*'",          # single-quoted string ('' is an escaped quote)
    "&[A-Za-z_]\\w*\\.?",      # macro variable reference
    "%[A-Za-z_]\\w*",          # macro statement or macro call
    "\\b\\d+(?:\\.\\d+)?\\b",  # numeric literal
    kw, cf, ot,
    sep = "|")

  m <- gregexpr(pattern, code, perl = TRUE)[[1]]
  if (m[1] == -1L) return(gsub("\r\n|\r|\n", "&#10;", .viya_html_escape(code)))

  lens <- attr(m, "match.length")
  cls_for <- function(token) {
    if (startsWith(token, "/*") || startsWith(token, "*")) "co"
    else if (startsWith(token, '"') || startsWith(token, "'")) "st"
    else if (startsWith(token, "&")) "va"
    else if (startsWith(token, "%")) "fu"
    else if (grepl("^[0-9]", token)) "dv"
    else if (toupper(token) %in% .viya_sas_control_flow) "cf"
    else if (toupper(token) %in% .viya_sas_procs) "ot"
    else "kw"
  }

  out <- character(0)
  pos <- 1L
  for (i in seq_along(m)) {
    start <- m[i]; len <- lens[i]
    if (start > pos) out <- c(out, .viya_html_escape(substr(code, pos, start - 1L)))
    token <- substr(code, start, start + len - 1L)
    out <- c(out, paste0('<span class="', cls_for(token), '">',
                          .viya_html_escape(token), '</span>'))
    pos <- start + len
  }
  if (pos <= nchar(code)) out <- c(out, .viya_html_escape(substr(code, pos, nchar(code))))
  gsub("\r\n|\r|\n", "&#10;", paste(out, collapse = ""))
}

# Builds the whole chunk output (code echo + log/listing + isolated ODS
# html) as one markdown/HTML string, returned via knitr::asis_output() so
# it is spliced in verbatim regardless of the chunk's own `results`
# option -- the formatting decisions here (fencing, iframe isolation) are
# made once, by this function, not deferred to knitr's own
# results-handling rules.
#
# The highlighted sourceCode block is raw HTML -- pandoc only passes raw
# HTML blocks through for an HTML-family writer; for any other target
# (confirmed live: latex, i.e. a PDF render) it silently drops them
# entirely, not just their styling, so the whole code echo would vanish
# from a PDF/docx/Typst render. knitr::pandoc_to() (backed by quarto's own
# `rmarkdown.pandoc.to` knit option, confirmed empirically to read "html"
# for an HTML target and "latex" for PDF) gates that raw HTML behind an
# actual HTML target and falls back to a plain fenced code block
# otherwise -- unstyled, but it survives every pandoc writer. The same
# fallback applies when the target is unknown (i.e. not running inside an
# actual pandoc render at all), since raw HTML is only safe to emit once
# an HTML target is confirmed, not assumed.
.viya_sas_render <- function(options, code, result) {
  parts <- character(0)
  if (!identical(options$echo, FALSE))
    parts <- c(parts, if (identical(knitr::pandoc_to(), "html")) {
      paste0(
        '<div class="sourceCode"><pre class="sourceCode sas">',
        '<code class="sourceCode sas">', .viya_sas_highlight(code),
        '</code></pre></div>')
    } else {
      paste0("```sas\n", code, "\n```")
    })
  if (!is.null(result$log) && length(result$log))
    parts <- c(parts, paste0("```\n", paste(result$log, collapse = "\n"), "\n```"))
  if (!is.null(result$listing) && length(result$listing))
    parts <- c(parts, paste0("```\n", paste(result$listing, collapse = "\n"), "\n```"))
  if (!is.null(result$html) && length(result$html))
    parts <- c(parts, vapply(unname(result$html), .viya_html_iframe, character(1)))
  knitr::asis_output(paste(parts, collapse = "\n\n"))
}

# Pushes each named R data.frame (resolved in knitr::knit_global(), the
# same way .viya_resolve_session() resolves `session`) into SAS as
# WORK.<name> before the chunk's own code runs, so that code can reference
# it directly (e.g. `proc print data=work.mydata; run;`). Errors mirror
# .viya_resolve_session()'s wording for the same two failure modes (an
# unbound name, or an object of the wrong type), so both chunk options
# fail the same recognizable way.
.viya_sas_push_inputs <- function(h, input) {
  for (name in input) {
    if (!exists(name, envir = knitr::knit_global()))
      stop("`sas.input: ", name, "` does not name any object in the knit ",
           "environment.", call. = FALSE)
    df <- get(name, envir = knitr::knit_global())
    if (!is.data.frame(df))
      stop("`sas.input: ", name, "` does not resolve to a data.frame (see ",
           "viya_write()).", call. = FALSE)
    viya_write(h, df, "WORK", name)
  }
}

# "libref.table" -> list(libref, table); a bare table name defaults its
# libref to "work", the same default viya_write() itself writes to.
.viya_sas_parse_libref_table <- function(spec) {
  parts <- strsplit(spec, ".", fixed = TRUE)[[1]]
  if (length(parts) < 2L) list(libref = "work", table = parts[1])
  else list(libref = parts[1], table = paste(parts[-1], collapse = "."))
}

# Reads a SAS dataset back into an R data.frame after the chunk's code
# runs, and assigns it into knitr::knit_global() under `var` (defaulting
# to the table's own name) -- the mirror image of .viya_sas_push_inputs(),
# so a *later* chunk can reference the result by name exactly like it
# already does for `session`. `max_rows` is left unset (viya_read()'s own
# 100000-row safety default applies) unless the chunk overrides it via
# `sas.output_max_rows` -- see viya_read()'s own docs for why that cap
# exists: it's a client-side guard against pulling an entire CAS-sized
# table into memory, not a REST pagination limit.
.viya_sas_pull_output <- function(h, output_data, var, max_rows = NULL) {
  lt <- .viya_sas_parse_libref_table(output_data)
  df <- if (is.null(max_rows)) viya_read(h, lt$libref, lt$table)
        else viya_read(h, lt$libref, lt$table, max_rows = max_rows)
  assign(var %||% lt$table, df, envir = knitr::knit_global())
}

# The knit_engines$set(sas = ...) callback (registered in R/zzz.R). Takes
# the full chunk options list (knitr's own contract for custom engines --
# code lives at options$code, one element per source line) and returns
# the rendered chunk output.
.viya_sas_engine <- function(options) {
  if (isFALSE(options$eval))
    return(knitr::engine_output(options, options$code, ""))
  h <- .viya_resolve_session(options$session)
  if (!is.null(options$sas.input)) .viya_sas_push_inputs(h, options$sas.input)
  code <- paste(options$code, collapse = "\n")
  result <- viya_submit_quarto(
    h, code,
    output = options$viya.output %||% "html",
    poll_s = options$viya.poll_s %||% 1,
    timeout_s = options$viya.timeout_s %||% 300,
    error = isTRUE(options$viya.error))
  if (!is.null(options$sas.output_data) && identical(result$state, "completed"))
    .viya_sas_pull_output(h, options$sas.output_data, options$sas.output_var,
                          options$sas.output_max_rows)
  .viya_sas_render(options, code, result)
}
