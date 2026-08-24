local_token_cache <- function(.env = parent.frame()) {
  old <- as.list(.token_cache, all.names = TRUE)
  withr::defer({
    rm(list = ls(envir = .token_cache, all.names = TRUE), envir = .token_cache)
    list2env(old, .token_cache)
  }, envir = .env)
}
