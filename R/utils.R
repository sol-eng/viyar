`%||%` <- function(a, b) if (is.null(a)) b else a

.viya_is_transient <- function(resp) {
  httr2::resp_status(resp) %in% c(429, 503)
}

.viya_error_body <- function(resp) {
  body <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
  if (is.null(body)) return(NULL)
  msg <- body[["message"]] %||% body[["error_description"]] %||% body[["error"]]
  rem <- body[["remediation"]]
  out <- paste(c(msg, rem), collapse = " ")
  if (!nzchar(out)) return(NULL)
  out
}

# Joins a base URL to a path with exactly one separator, whichever side
# carries (or omits) the slash. Both sides are untrusted: the base comes
# from user input or VIYA_URL, which is commonly set with a trailing "/"
# (Viya 404s "There is no handler defined for the path" on the resulting
# "//compute/..."), and some paths are hrefs the service hands back --
# see .viya_result_path(), whose base-stripping can drop the leading "/".
.viya_url <- function(base, path) {
  paste0(sub("/+$", "", base), "/", sub("^/+", "", path))
}

.viya_req <- function(h, path) {
  httr2::request(.viya_url(h$base, path)) |>
    httr2::req_auth_bearer_token(h$token) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3, is_transient = .viya_is_transient) |>
    httr2::req_error(body = .viya_error_body)
}

#' Check whether the Viya server is reachable
#'
#' Fast TCP/HTTP probe used to gate connection attempts on unstable networks.
#' Any HTTP response (including 401) counts as reachable.
#'
#' @param url Viya base URL. Defaults to the configured URL
#'   (see [viya_config()]).
#' @param timeout_s Probe timeout in seconds.
#' @param insecure Skip TLS certificate/host verification. Only set this
#'   for a cluster with a self-signed certificate you already trust —
#'   the default verifies TLS. Defaults to the `viyar.insecure` option if
#'   set, otherwise `FALSE`.
#' @return `TRUE` if the server answered, `FALSE` otherwise.
#' @examples
#' \dontrun{
#' viya_reachable()
#' }
#' @export
viya_reachable <- function(url = viya_config()$url, timeout_s = 5,
                           insecure = getOption("viyar.insecure", FALSE)) {
  tryCatch({
    hd <- curl::new_handle(timeout = timeout_s, connecttimeout = timeout_s,
                           ssl_verifypeer = !insecure, ssl_verifyhost = !insecure)
    curl::curl_fetch_memory(url, handle = hd); TRUE
  }, error = function(e) FALSE)
}

#' Decode a JWT's `exp` claim
#'
#' Used to know when a cached access token expires ahead of time, rather
#' than discovering it via a 401 mid-workflow.
#'
#' @param token A JWT access token (or any string — non-JWTs return `NA`).
#' @return A POSIXct expiry time, or `NA` if `token` isn't a parseable
#'   JWT with an `exp` claim.
.jwt_exp <- function(token) {
  parts <- strsplit(token, ".", fixed = TRUE)[[1]]
  if (length(parts) < 2) return(as.POSIXct(NA))
  b64 <- chartr("-_", "+/", parts[2])
  b64 <- paste0(b64, strrep("=", (4 - nchar(b64) %% 4) %% 4))
  payload <- tryCatch(
    jsonlite::fromJSON(rawToChar(openssl::base64_decode(b64))),
    error = function(e) NULL)
  if (is.null(payload$exp)) return(as.POSIXct(NA))
  as.POSIXct(payload$exp, origin = "1970-01-01", tz = "UTC")
}
