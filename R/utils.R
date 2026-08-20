`%||%` <- function(a, b) if (is.null(a)) b else a

.viya_req <- function(h, path) {
  httr2::request(paste0(h$base, path)) |>
    httr2::req_auth_bearer_token(h$token) |>
    httr2::req_timeout(120)
}

#' Check whether the Viya server is reachable
#'
#' Fast TCP/HTTP probe used to gate connection attempts on unstable networks.
#' Any HTTP response (including 401) counts as reachable.
#'
#' @param url Viya base URL. Defaults to the configured URL
#'   (see [viya_config()]).
#' @param timeout_s Probe timeout in seconds.
#' @return `TRUE` if the server answered, `FALSE` otherwise.
#' @examples
#' \dontrun{
#' viya_reachable()
#' }
#' @export
viya_reachable <- function(url = viya_config()$url, timeout_s = 5) {
  tryCatch({
    hd <- curl::new_handle(timeout = timeout_s, connecttimeout = timeout_s,
                           ssl_verifypeer = FALSE, ssl_verifyhost = FALSE)
    curl::curl_fetch_memory(url, handle = hd); TRUE
  }, error = function(e) FALSE)
}
