.pkce_verifier <- function() {
  alphabet <- c(letters, LETTERS, 0:9, "-", ".", "_", "~")
  paste0(sample(alphabet, 64, replace = TRUE), collapse = "")
}

.pkce_challenge <- function(verifier) {
  digest <- openssl::sha256(charToRaw(verifier))
  b64 <- openssl::base64_encode(digest)
  chartr("+/", "-_", sub("=+$", "", b64))
}
