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
