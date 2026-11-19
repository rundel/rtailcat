#' Generate tailcat keys
#'
#' Generates a node key pair and a random pre-shared key locally, without network access. Pass the result as the `key` of a [TailcatServer] to give a server a stable identity and address across restarts, or pass it as the `key` of a [TailcatClient] to give a client a stable public key (useful with `allowed_clients`).
#'
#' The private key and the pre-shared key are secrets. They are [tailcat_secret] strings, so `print()`, `format()`, and `str()` of the keys, or of the elements, show only the public key and `<redacted>`. The elements still hold the full values (`as.character()` or `unclass()` returns them, and `dput()` shows them), so store them securely: [tailcat_keys_save()] writes them to a file only you can read.
#'
#' @param path `NULL` (the default) to return new keys without saving them, or the path of a keys file: if it exists, the keys are loaded from it with [tailcat_keys_load()]; otherwise new keys are generated and saved there with [tailcat_keys_save()]. This gives a script the same keys every time it runs.
#' @return A list of class `tailcat_keys` with elements `private_key`, `public_key`, and `preshared_key`, each a string in tailcat's text encoding; `private_key` and `preshared_key` are [tailcat_secret] strings.
#' @examples
#' keys = tailcat_keygen()
#' keys
#' keys$public_key
#' @export
tailcat_keygen = function(path = NULL) {
  if (!is.null(path)) {
    path = check_path(path)
    if (file.exists(path)) {
      return(tailcat_keys_load(path))
    }
  }
  keys = from_json(rtc_value(rtc_key_generate(), op = "generate keys"))
  keys = new_keys(keys$private_key, keys$public_key, keys$preshared_key)
  if (!is.null(path)) {
    tailcat_keys_save(keys, path)
  }
  keys
}

#' @export
format.tailcat_keys = function(x, ...) {
  c(
    "<tailcat_keys>",
    paste0("  public_key:    ", x$public_key %||% "<none>"),
    "  private_key:   <redacted>",
    "  preshared_key: <redacted>"
  )
}

#' @export
print.tailcat_keys = function(x, ...) {
  cat(format(x, ...), sep = "\n")
  invisible(x)
}

#' @exportS3Method utils::str
str.tailcat_keys = function(object, ...) {
  cat("List of 3 (class tailcat_keys)\n")
  cat(" $ private_key  : <tailcat_secret>", secret_label, "\n")
  cat(
    " $ public_key   : chr",
    encodeString(object$public_key %||% NA_character_, quote = '"'),
    "\n"
  )
  cat(" $ preshared_key: <tailcat_secret>", secret_label, "\n")
  invisible(object)
}

new_keys = function(private_key, public_key, preshared_key) {
  structure(
    list(
      private_key = new_secret(private_key),
      public_key = public_key,
      preshared_key = new_secret(preshared_key)
    ),
    class = "tailcat_keys"
  )
}
