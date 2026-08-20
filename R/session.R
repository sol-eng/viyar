#' List available compute contexts
#'
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return A data frame with columns `name` and `id`.
#' @examples
#' \dontrun{
#' viya_contexts()
#' }
#' @export
viya_contexts <- function(token = viya_token(), url = viya_config()$url) {
  h <- list(token = token, base = url)
  ctx <- .viya_req(h, "/compute/contexts?limit=100") |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(name = vapply(ctx$items, `[[`, "", "name"),
             id   = vapply(ctx$items, `[[`, "", "id"))
}

#' Start a Viya compute session
#'
#' Looks up the compute context by name, gates every attempt on server
#' reachability (so attempts are not wasted against a down network), and
#' retries through transient pod-launch timeouts (Viya errorCode 5830).
#'
#' @param context Compute context name; defaults to the configured context.
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @param tries Maximum connection attempts.
#' @param wait Seconds to wait between attempts.
#' @return A `viyar` session handle used by all other functions.
#' @examples
#' \dontrun{
#' h <- viya_session()
#' viya_end(h)
#' }
#' @export
viya_session <- function(context = viya_config()$context,
                         token = viya_token(),
                         url = viya_config()$url,
                         tries = 5, wait = 20) {
  if (!nzchar(url)) stop("No Viya URL configured. viya_config(url = ...) ",
                         "or set VIYA_URL.")
  ctxs <- viya_contexts(token, url)
  hit  <- ctxs$id[ctxs$name == context]
  if (!length(hit)) stop("Context '", context, "' not found. Available:\n  ",
                         paste(ctxs$name, collapse = "\n  "))
  h <- list(token = token, base = url)
  for (i in seq_len(tries)) {
    if (!viya_reachable(url)) {
      message("viya unreachable, waiting ", wait, "s (", i, "/", tries, ")")
      Sys.sleep(wait); next
    }
    res <- tryCatch(
      .viya_req(h, paste0("/compute/contexts/", hit[1], "/sessions")) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(list(version = 1, name = "viyar-session")) |>
        httr2::req_perform() |> httr2::resp_body_json(),
      error = function(e) e)
    if (!inherits(res, "error")) {
      message("compute session started: ", res$id)
      return(structure(list(token = token, session = res$id,
                            context = context, base = url),
                       class = "viyar"))
    }
    message("attempt ", i, " failed: ",
            substr(conditionMessage(res), 1, 120))
    Sys.sleep(wait)
  }
  stop("could not start a compute session after ", tries, " attempts")
}

#' Print a viyar session handle
#'
#' @param x A `viyar` handle from [viya_session()].
#' @param ... Ignored.
#' @return `x`, invisibly.
#' @export
print.viyar <- function(x, ...) {
  cat("<viyar compute session>\n",
      " server : ", x$base, "\n",
      " context: ", x$context, "\n",
      " session: ", x$session, "\n", sep = "")
  invisible(x)
}

#' End a compute session
#'
#' @param h A `viyar` handle from [viya_session()].
#' @return `TRUE` on success, `FALSE` otherwise (invisibly).
#' @examples
#' \dontrun{
#' h <- viya_session(); viya_end(h)
#' }
#' @export
viya_end <- function(h) {
  stopifnot(inherits(h, "viyar"))
  invisible(tryCatch({
    .viya_req(h, paste0("/compute/sessions/", h$session)) |>
      httr2::req_method("DELETE") |> httr2::req_perform()
    message("compute session ended: ", h$session)
    TRUE
  }, error = function(e) { message("end failed: ", conditionMessage(e)); FALSE }))
}

#' List your compute sessions on the server
#'
#' Useful for spotting and cleaning up leaked sessions.
#'
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return A data frame with columns `id` and `state`.
#' @export
viya_sessions <- function(token = viya_token(), url = viya_config()$url) {
  h <- list(token = token, base = url)
  r <- .viya_req(h, "/compute/sessions?limit=100") |>
    httr2::req_perform() |> httr2::resp_body_json()
  data.frame(id    = vapply(r$items, `[[`, "", "id"),
             state = vapply(r$items, function(x) x$state %||% "", ""))
}

#' Terminate a compute session by id
#'
#' @param session_id Compute session id (see [viya_sessions()]).
#' @param token Viya access token; defaults to [viya_token()].
#' @param url Viya base URL; defaults to the configured URL.
#' @return The response, invisibly.
#' @export
viya_kill <- function(session_id, token = viya_token(),
                      url = viya_config()$url) {
  h <- list(token = token, base = url)
  invisible(.viya_req(h, paste0("/compute/sessions/", session_id)) |>
              httr2::req_method("DELETE") |> httr2::req_perform())
}
