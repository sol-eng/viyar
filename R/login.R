.pkce_verifier <- function() {
  raw <- openssl::rand_bytes(32)
  b64 <- openssl::base64_encode(raw)
  chartr("+/", "-_", sub("=+$", "", b64))
}

.pkce_challenge <- function(verifier) {
  digest <- openssl::sha256(charToRaw(verifier))
  b64 <- openssl::base64_encode(digest)
  chartr("+/", "-_", sub("=+$", "", b64))
}

.parse_auth_code <- function(input) {
  input <- trimws(input)
  if (!nzchar(input)) stop("No authorization code provided.")
  if (!grepl("^https?://", input)) return(input)

  query <- sub("^[^?]*\\?", "", sub("#.*$", "", input))
  pairs <- strsplit(query, "&", fixed = TRUE)[[1]]
  kv <- strsplit(pairs, "=", fixed = TRUE)
  keys <- vapply(kv, `[`, "", 1)
  vals <- vapply(kv, function(x) if (length(x) > 1) x[2] else "", "")
  names(vals) <- keys

  err <- unname(vals["error"])
  if (!is.na(err) && nzchar(err))
    stop("Viya login failed: ", utils::URLdecode(
      if (!is.na(vals["error_description"])) unname(vals["error_description"])
      else err))
  code <- unname(vals["code"])
  if (is.na(code) || !nzchar(code))
    stop("No code parameter found in the pasted URL.")
  utils::URLdecode(code)
}

.viya_token_exchange <- function(url, body) {
  httr2::request(paste0(url, "/SASLogon/oauth/token")) |>
    httr2::req_headers(Accept = "application/json") |>
    httr2::req_timeout(30) |>
    (\(req) do.call(httr2::req_body_form, c(list(req), body)))() |>
    httr2::req_error(body = .viya_error_body) |>
    httr2::req_perform() |> httr2::resp_body_json()
}

.viya_cache_token <- function(resp, client_id, url = .token_cache$url) {
  .token_cache$tok <- resp$access_token
  .token_cache$refresh <- resp$refresh_token %||% .token_cache$refresh
  .token_cache$exp <- .jwt_exp(resp$access_token)
  .token_cache$client_id <- client_id
  .token_cache$url <- url
  invisible(resp$access_token)
}

#' Log in to Viya interactively via browser SSO
#'
#' For use outside Posit Workbench (e.g. a local desktop R session):
#' opens a Viya login page in your browser using the OAuth authorization
#' code flow with PKCE, then exchanges the code you paste back for an
#' access token. The token (and refresh token, if issued) is cached and
#' picked up automatically by [viya_token()] and [viya_session()] for the
#' rest of the R session, refreshing itself silently as it nears expiry.
#'
#' @param url Viya base URL; defaults to the configured URL (see
#'   [viya_config()]).
#' @param client_id OAuth client id registered on the Viya server for
#'   interactive/CLI logins.
#' @param redirect_uri Redirect URI to send in the authorization request.
#'   Defaults to the OAuth out-of-band value
#'   (`"urn:ietf:wg:oauth:2.0:oob"`), which is SAS's documented redirect
#'   for CLI-style logins where the code is copy-pasted back rather than
#'   captured by a listening redirect target. Pass `NULL` to omit it
#'   entirely and rely on the server's registered default for
#'   `client_id`, if you know that's what your deployment expects.
#' @param scope OAuth scopes to request.
#' @return The access token (character scalar), invisibly.
#' @examples
#' \dontrun{
#' viya_login(url = "https://viya.example.com")
#' h <- viya_session()
#' }
#' @export
viya_login <- function(url = viya_config()$url,
                       client_id = "vscode-positron",
                       redirect_uri = "urn:ietf:wg:oauth:2.0:oob",
                       scope = "openid") {
  if (!nzchar(url)) stop("No Viya URL configured. viya_config(url = ...) ",
                         "or set VIYA_URL.")

  verifier  <- .pkce_verifier()
  challenge <- .pkce_challenge(verifier)

  q <- list(client_id = client_id, response_type = "code", scope = scope,
            code_challenge = challenge, code_challenge_method = "S256")
  if (!is.null(redirect_uri)) q$redirect_uri <- redirect_uri
  authorize_url <- do.call(httr2::url_modify_query,
                           c(list(paste0(url, "/SASLogon/oauth/authorize")), q))

  message("Opening Viya login in your browser:\n", authorize_url)
  tryCatch(utils::browseURL(authorize_url), error = function(e) NULL)

  raw <- readline(
    "After logging in, paste the authorization code (or the full redirect URL) here: ")
  code <- .parse_auth_code(raw)

  body <- list(grant_type = "authorization_code", client_id = client_id,
               code = code, code_verifier = verifier)
  if (!is.null(redirect_uri)) body$redirect_uri <- redirect_uri
  resp <- .viya_token_exchange(url, body)
  tok  <- .viya_cache_token(resp, client_id, url)
  message("Viya login succeeded; token cached",
          if (!is.na(.token_cache$exp))
            paste0(" (expires ", format(.token_cache$exp, usetz = TRUE), ")")
          else "", ".")
  invisible(tok)
}
