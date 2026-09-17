.onLoad <- function(libname, pkgname) {
  if (requireNamespace("knitr", quietly = TRUE)) {
    knitr::knit_engines$set(sas = .viya_sas_engine)
  }
}
