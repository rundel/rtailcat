#' Secret strings
#'
#' @description
#' Tailcat addresses, private keys, and pre-shared keys are returned as character vectors with class `tailcat_secret`, so that printing them by accident does not reveal them. `TailcatServer$address`, the `address` element of `TailcatServer$info()`, the result of [tailcat_address_resolve()], and the `private_key` and `preshared_key` elements of [tailcat_keygen()] are secrets.
#'
#' `print()`, `format()`, `str()`, and `toString()` show `<redacted>` instead of the value, and so do printing and `str()` of a list that contains a secret. `format()` of a plain list that contains a secret redacts it in R 4.6.0 and later; earlier versions of R format list elements without consulting their class, so there it shows the value.
#'
#' Everything else sees the plain string: `as.character()`, `unclass()`, `paste()`, `paste0()`, `cat()`, `writeLines()`, `nchar()`, and `identical()` on the unclassed value. A secret can be passed directly wherever this package expects an address or key, such as `TailcatClient$new()` and `TailcatServer$new()`. Functions that drop attributes, such as `c()`, `unlist()`, and subsetting with `[`, return the plain string too.
#'
#' Redaction only protects against accidental display. `dput()`, `deparse()`, `saveRDS()`, and `save()` necessarily include the value, as does any explicit conversion with `as.character()` or `unclass()`, so store and share secrets deliberately.
#'
#' @param x,object A `tailcat_secret`.
#' @param ... Ignored.
#' @return `format()` and `toString()` return `"<redacted>"` for each element; `print()` and `str()` return their input invisibly.
#' @examples
#' keys = tailcat_keygen()
#' keys$private_key
#' str(keys)
#' nchar(keys$private_key) > 0
#' @name tailcat_secret
NULL

new_secret = function(x) {
  structure(as.character(x), class = "tailcat_secret")
}

secret_label = "<redacted>"

#' @rdname tailcat_secret
#' @export
format.tailcat_secret = function(x, ...) {
  rep_len(secret_label, length(x))
}

#' @rdname tailcat_secret
#' @export
print.tailcat_secret = function(x, ...) {
  cat("<tailcat_secret>", secret_label, "\n")
  invisible(x)
}

#' @rdname tailcat_secret
#' @exportS3Method utils::str
str.tailcat_secret = function(object, ...) {
  cat(" <tailcat_secret>", secret_label, "\n")
  invisible(object)
}

#' @rdname tailcat_secret
#' @export
toString.tailcat_secret = function(x, ...) {
  secret_label
}

# Strips the class so a secret can be validated and passed on like a string.
reveal = function(x) {
  if (inherits(x, "tailcat_secret")) unclass(x) else x
}
