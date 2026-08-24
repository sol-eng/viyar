.viya_url_from_integration <- function(int) {
  src <- int$issuer %||% int$token_url %||% int$auth_url
  if (is.null(src)) return(NULL)
  sub("/SASLogon/.*$", "", src)
}

.viya_in_workbench_session <- function() {
  # Mirrors rstudioapi's own internal assertWorkbenchSession() check --
  # a plain env-var check, inherited by any subprocess (including a
  # detached `quarto render`), unlike rstudioapi::isAvailable(), which
  # checks a stricter, unrelated "is this an RStudio-family GUI frontend"
  # condition that findOAuthIntegration()/getOAuthCredentials() don't
  # actually depend on.
  identical(Sys.getenv("POSIT_PRODUCT"), "WORKBENCH") ||
    nzchar(Sys.getenv("RS_SERVER_ADDRESS"))
}

.viya_no_url_error <- function() {
  msg <- "No Viya URL configured. viya_config(url = ...) or set VIYA_URL."
  if (!.viya_in_workbench_session()) {
    msg <- paste0(msg, " Note: this process isn't running inside a Posit ",
                  "Workbench session (env POSIT_PRODUCT/RS_SERVER_ADDRESS ",
                  "not set) -- e.g. local desktop R, or `quarto render` run ",
                  "outside Workbench entirely. Set VIYA_URL, call ",
                  "viya_config(url = ...) explicitly, or use viya_login().")
  }
  msg
}

#' Get or set viyar configuration
#'
#' Configuration is resolved from R options first, then environment
#' variables: `url` (option `viyar.url` / env `VIYA_URL`; if still unset
#' and running inside Posit Workbench, auto-detected from the matching
#' OAuth integration's issuer URL), `context` (option `viyar.context` /
#' env `VIYA_CONTEXT`, default `"SAS Studio compute context"`),
#' `cas_server` (option `viyar.cas_server` / env `VIYA_CAS_SERVER`,
#' default `"cas-shared-default"`), and `wb_integration` (option
#' `viyar.wb_integration` / env `VIYA_WB_INTEGRATION`, a regex matching the
#' Posit Workbench managed-credential integration name, default
#' `"^sas-viya$"`).
#'
#' @param ... Named values to set, e.g.
#'   `viya_config(url = "https://viya.example.com")`.
#' @return The current configuration as a named list (invisibly when
#'   setting values).
#' @examples
#' \dontrun{
#' viya_config(url = "https://viya.example.com")
#' viya_config()
#' }
#' @export
viya_config <- function(...) {
  new <- list(...)
  for (nm in names(new)) options(structure(list(new[[nm]]),
                                           names = paste0("viyar.", nm)))

  wb_integration <- getOption("viyar.wb_integration",
                              Sys.getenv("VIYA_WB_INTEGRATION",
                                         unset = "^sas-viya$"))
  url <- getOption("viyar.url", Sys.getenv("VIYA_URL", unset = ""))
  if (!nzchar(url) && requireNamespace("rstudioapi", quietly = TRUE)) {
    # findOAuthIntegration() gates itself on a genuine Workbench session
    # (an internal, env-var-based check -- see .viya_in_workbench_session())
    # rather than rstudioapi::isAvailable(), so no extra gate is needed
    # here; tryCatch lets it fail silently and fall through otherwise.
    int <- tryCatch(rstudioapi::findOAuthIntegration(name = wb_integration),
                    error = function(e) NULL)
    if (!is.null(int)) url <- .viya_url_from_integration(int) %||% ""
  }

  cfg <- list(
    url = sub("/+$", "", url),
    context = getOption("viyar.context",
                        Sys.getenv("VIYA_CONTEXT",
                                   unset = "SAS Studio compute context")),
    cas_server = getOption("viyar.cas_server",
                           Sys.getenv("VIYA_CAS_SERVER",
                                      unset = "cas-shared-default")),
    wb_integration = wb_integration
  )
  if (length(new)) invisible(cfg) else cfg
}

.token_cache <- new.env(parent = emptyenv())

#' Obtain a Viya access token
#'
#' Resolution order: the `VIYA_TOKEN` environment variable if set; a
#' still-fresh cached token from a previous call; Posit Workbench managed
#' OAuth credentials via `rstudioapi` (interactive Workbench sessions);
#' a cached SSO token from [viya_login()], refreshed silently if it's
#' expired or about to expire. On Posit Connect with viewer OAuth
#' integrations, obtain the token yourself (e.g.
#' `connectapi::get_oauth_credentials()` with the viewer session token) and
#' pass it to [viya_session()] via its `token` argument.
#'
#' @param refresh Force re-acquisition instead of returning a still-fresh
#'   cached token (Viya access tokens typically last around 10 hours).
#' @return An OAuth access token (character scalar).
#' @examples
#' \dontrun{
#' tok <- viya_token()
#' }
#' @export
viya_token <- function(refresh = FALSE) {
  tok <- Sys.getenv("VIYA_TOKEN", unset = "")
  if (nzchar(tok)) return(tok)

  if (!refresh && !is.null(.token_cache$tok) &&
      (is.null(.token_cache$exp) || is.na(.token_cache$exp) ||
       .token_cache$exp > Sys.time() + 60)) {
    return(.token_cache$tok)
  }

  if (requireNamespace("rstudioapi", quietly = TRUE)) {
    # findOAuthIntegration()/getOAuthCredentials() gate themselves on a
    # genuine Workbench session (an internal, env-var-based check -- see
    # .viya_in_workbench_session() -- inherited by any subprocess,
    # including a detached `quarto render`), not on
    # rstudioapi::isAvailable(), which checks a stricter, unrelated "is
    # this an RStudio-family GUI frontend" condition. No extra gate is
    # needed here; both calls are wrapped in tryCatch to fall through to
    # the next resolution step (rather than error) whenever they're not
    # in a real Workbench session (plain RStudio Desktop, a local
    # Positron session with no Workbench attached, or no Workbench at
    # all).
    int <- tryCatch(
      rstudioapi::findOAuthIntegration(name = viya_config()$wb_integration),
      error = function(e) NULL)
    if (!is.null(int)) {
      tok <- tryCatch(
        rstudioapi::getOAuthCredentials(audience = int$guid)$access_token,
        error = function(e) NULL)
      if (!is.null(tok)) {
        .token_cache$tok <- tok
        .token_cache$refresh <- NULL
        .token_cache$exp <- .jwt_exp(tok)
        return(tok)
      }
    }
  }

  if (!is.null(.token_cache$refresh)) {
    refresh_url <- .token_cache$url %||% viya_config()$url
    resp <- tryCatch(
      .viya_token_exchange(refresh_url, list(
        grant_type = "refresh_token",
        client_id = .token_cache$client_id,
        refresh_token = .token_cache$refresh)),
      error = function(e) {
        message("Viya token refresh failed: ", conditionMessage(e))
        NULL
      })
    if (!is.null(resp)) return(.viya_cache_token(resp, .token_cache$client_id, refresh_url))
  }

  stop("No Viya token available. Set VIYA_TOKEN, run inside Posit Workbench ",
       "with a matching OAuth integration, or call viya_login() to ",
       "authenticate interactively.")
}
