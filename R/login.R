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
