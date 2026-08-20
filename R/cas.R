#' List source files in a caslib's data store
#'
#' Source files (`.sashdat`, `.csv`, ...) sit on disk and are invisible to
#' table listings until loaded into memory (see [viya_load_table()]).
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param caslib Caslib name, e.g. `"Public"`.
#' @param cas_server CAS server name; defaults to the configured value.
#' @return A data frame with columns `name` and `size` (bytes).
#' @export
viya_caslib_files <- function(h, caslib,
                              cas_server = viya_config()$cas_server) {
  r <- .viya_req(h, paste0("/casManagement/servers/", cas_server,
                           "/caslibs/", utils::URLencode(caslib),
                           "/sources?limit=500")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(
    name = vapply(r$items, `[[`, "", "name"),
    size = vapply(r$items, function(x) x$sizeInBytes %||% NA_real_,
                  numeric(1)))
}

#' List caslib tables with loaded/unloaded state
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param caslib Caslib name.
#' @param cas_server CAS server name; defaults to the configured value.
#' @return A data frame with columns `name` and `state`.
#' @export
viya_caslib_tables <- function(h, caslib,
                               cas_server = viya_config()$cas_server) {
  r <- .viya_req(h, paste0("/casManagement/servers/", cas_server,
                           "/caslibs/", utils::URLencode(caslib),
                           "/tables?limit=500")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(
    name  = vapply(r$items, `[[`, "", "name"),
    state = vapply(r$items, function(x) x$state %||% "", ""))
}

#' Load a caslib source file into CAS memory
#'
#' Runs `PROC CASUTIL` in the compute session, maintaining one persistent
#' CAS session (`_VIYARC_`) inside it.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param caslib Caslib containing the source file.
#' @param file Source file name including extension, e.g.
#'   `"orders.sashdat"`.
#' @param casout In-memory table name (defaults to the file name without
#'   extension, uppercased).
#' @param promote If `TRUE` (default), give the loaded table global scope:
#'   visible to all sessions and clients (e.g. a swat-based Shiny app) and
#'   it survives this compute session. If `FALSE`, the table is scoped to
#'   this compute session's CAS session only.
#' @param replace Drop an existing table of the same name first. `promote`
#'   and `replace` are mutually exclusive in CASUTIL; `replace` wins if
#'   both are `TRUE`.
#' @return The [viya_submit()] result, invisibly.
#' @examples
#' \dontrun{
#' viya_load_table(h, "Public", "orders.sashdat", promote = TRUE)
#' }
#' @export
viya_load_table <- function(h, caslib, file,
                            casout = toupper(sub("\\.[^.]+$", "", file)),
                            promote = TRUE, replace = FALSE) {
  opt <- if (replace) "replace" else if (promote) "promote" else ""
  code <- sprintf(paste0(
    "%%macro _viyar_cas; ",
    "%%if %%sysfunc(sessfound(_VIYARC_)) = 0 %%then %%do;\n",
    "  cas _VIYARC_;\n%%end; %%mend; %%_viyar_cas;\n",
    "proc casutil session=_VIYARC_ incaslib=\"%s\" outcaslib=\"%s\";\n",
    "  load casdata=\"%s\" casout=\"%s\" %s;\nquit;"),
    caslib, caslib, file, casout, opt)
  r <- viya_submit(h, code)
  if (!identical(r$state, "completed"))
    warning("load state: ", r$state, " - check r$log")
  message("load ", caslib, "/", file, " -> ", casout,
          if (nzchar(opt)) paste0(" (", opt, ")") else "", ": ", r$state)
  invisible(r)
}

#' Unload a table from CAS memory
#'
#' The source file in the caslib data store is not affected.
#'
#' @param h A `viyar` handle from [viya_session()].
#' @param caslib Caslib name.
#' @param table In-memory table name.
#' @param cas_server CAS server name; defaults to the configured value.
#' @return The response, invisibly.
#' @export
viya_unload_table <- function(h, caslib, table,
                              cas_server = viya_config()$cas_server) {
  invisible(.viya_req(h, paste0("/casManagement/servers/", cas_server,
                                "/caslibs/", utils::URLencode(caslib),
                                "/tables/",
                                utils::URLencode(toupper(table)),
                                "/state?value=unloaded")) |>
              httr2::req_method("PUT") |> httr2::req_perform())
}
