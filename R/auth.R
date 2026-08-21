#' Get or set viyar configuration
#'
#' Configuration is resolved from R options first, then environment
#' variables: `url` (option `viyar.url` / env `VIYA_URL`), `context`
#' (option `viyar.context` / env `VIYA_CONTEXT`, default
#' `"SAS Studio compute context"`), `cas_server` (option
#' `viyar.cas_server` / env `VIYA_CAS_SERVER`, default
#' `"cas-shared-default"`), and `wb_integration` (option
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
  cfg <- list(
    url = sub("/+$", "",
          getOption("viyar.url", Sys.getenv("VIYA_URL", unset = ""))),
    context = getOption("viyar.context",
                        Sys.getenv("VIYA_CONTEXT",
                                   unset = "SAS Studio compute context")),
    cas_server = getOption("viyar.cas_server",
                           Sys.getenv("VIYA_CAS_SERVER",
                                      unset = "cas-shared-default")),
    wb_integration = getOption("viyar.wb_integration",
                               Sys.getenv("VIYA_WB_INTEGRATION",
                                          unset = "^sas-viya$"))
  )
  if (length(new)) invisible(cfg) else cfg
}

.token_cache <- new.env(parent = emptyenv())

#' Obtain a Viya access token
#'
#' Resolution order: the `VIYA_TOKEN` environment variable if set;
#' otherwise Posit Workbench managed OAuth credentials via `rstudioapi`
#' (interactive Workbench sessions). On Posit Connect with viewer OAuth
#' integrations, obtain the token yourself (e.g.
#' `connectapi::get_oauth_credentials()` with the viewer session token) and
#' pass it to [viya_session()] via its `token` argument.
#'
#' @param refresh Force re-acquisition instead of returning the cached
#'   token (Viya access tokens typically last around 10 hours).
#' @return An OAuth access token (character scalar).
#' @examples
#' \dontrun{
#' tok <- viya_token()
#' }
#' @export
viya_token <- function(refresh = FALSE) {
  if (!refresh && !is.null(.token_cache$tok)) return(.token_cache$tok)
  tok <- Sys.getenv("VIYA_TOKEN", unset = "")
  if (!nzchar(tok)) {
    if (!requireNamespace("rstudioapi", quietly = TRUE))
      stop("No VIYA_TOKEN env var and rstudioapi not available. ",
           "Provide a token explicitly.")
    int <- rstudioapi::findOAuthIntegration(
      name = viya_config()$wb_integration)
    if (is.null(int))
      stop("No OAuth integration matching '",
           viya_config()$wb_integration, "' found in Workbench.")
    tok <- rstudioapi::getOAuthCredentials(audience = int$guid)$access_token
  }
  .token_cache$tok <- tok
  tok
}
