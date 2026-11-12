#' Generate tailcat keys
#'
#' Generates a node key pair and a random pre-shared key locally, without network access. Pass the result as the `key` of a [TailcatServer] to give a server a stable identity and address across restarts, or pass it as the `key` of a [TailcatClient] to give a client a stable public key (useful with `allowed_clients`).
#'
#' The private key and the pre-shared key are secrets. They are [tailcat_secret] strings, so `print()`, `format()`, and `str()` of the keys, or of the elements, show only the public key and `<redacted>`. The elements still hold the full values (`as.character()` or `unclass()` returns them, and `dput()` shows them), so store them securely, for example with `saveRDS()` to a file only you can read.
#'
#' @return A list of class `tailcat_keys` with elements `private_key`, `public_key`, and `preshared_key`, each a string in tailcat's text encoding; `private_key` and `preshared_key` are [tailcat_secret] strings.
#' @examples
#' keys = tailcat_keygen()
#' keys
#' keys$public_key
#' @export
tailcat_keygen = function() {
  keys = from_json(rtc_value(rtc_key_generate(), op = "generate keys"))
  structure(
    list(
      private_key = new_secret(keys$private_key),
      public_key = keys$public_key,
      preshared_key = new_secret(keys$preshared_key)
    ),
    class = "tailcat_keys"
  )
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
  cat(" $ public_key   : chr", encodeString(object$public_key %||% NA_character_, quote = "\""), "\n")
  cat(" $ preshared_key: <tailcat_secret>", secret_label, "\n")
  invisible(object)
}

#' Inspect a tailcat address
#'
#' Parses a tailcat address locally, without network access, and returns its public metadata. The pre-shared key embedded in the address is deliberately not returned.
#'
#' @param address A tailcat address, as a string or the [tailcat_secret] returned by `TailcatServer$address`. Surrounding whitespace is ignored. Addresses are secrets.
#' @return A list with elements
#' - `public_key`, the server's public key;
#' - `disco_public_key`, the server's discovery key;
#' - `has_preshared_key`, `TRUE` if the address carries a pre-shared key;
#' - `region_id`, the number of the relay region the server registered in. `0` means the address names no region number: its relay details are embedded in `regions` instead, or (for an address that has neither) are missing, and a client cannot use it;
#' - `regions`, the relay regions embedded in the address, or `NULL`. Each is a list with `region_id`, `region_code`, `region_name`, and `nodes`; each node is a list with fields such as `name`, `region_id`, `host_name`, `cert_name`, `ipv4`, `ipv6`, `stun_port`, `relay_port`, and `insecure_for_tests` (fields tailcat omits are absent).
#'
#' Field names are snake_case versions of tailcat's (which follow Tailscale's `DERPRegion` and `DERPNode` types), with the relay (DERP) port as `relay_port`.
#' @examples
#' try(tailcat_address_parse("not an address"))
#' @export
tailcat_address_parse = function(address) {
  address = check_address(address)
  tailcat_fields(from_json(rtc_value(rtc_address_parse(address), op = "parse the address", arg = "address")))
}

#' Embed relay details in a tailcat address
#'
#' Returns a self-contained version of `address` with the relay (DERP) details embedded, fetching the relay map if needed. A resolved address avoids relay map discovery when a client connects, although connecting still needs network access. The result is a secret, like the input.
#'
#' @inheritParams tailcat_address_parse
#' @param derp_map_url URL of a relay map to use instead of the default, or `NULL`.
#' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls (see the section on timeouts in [TailcatServer]).
#' @return `tailcat_address_resolve()` returns the resolved address as a [tailcat_secret]. `tailcat_address_resolve_async()` returns a [promises::promise()] that resolves with it.
#' @export
tailcat_address_resolve = function(address, derp_map_url = NULL, timeout = 30) {
  address = check_address(address)
  derp_map_url = check_string(derp_map_url, "derp_map_url", null_ok = TRUE)
  timeout = check_timeout(timeout)
  new_secret(rtc_value(rtc_address_resolve(address, derp_map_url, timeout, NULL), op = "resolve the address", arg = "address", timeout = timeout))
}

#' @rdname tailcat_address_resolve
#' @export
tailcat_address_resolve_async = function(address, derp_map_url = NULL, timeout = 30) {
  address = check_address(address)
  derp_map_url = check_string(derp_map_url, "derp_map_url", null_ok = TRUE)
  timeout = check_timeout(timeout)
  rtc_promise(function(cb) rtc_address_resolve(address, derp_map_url, timeout, cb), new_secret, op = "resolve the address", arg = "address", timeout = timeout)
}

#' Build information for the embedded tailcat library
#'
#' @return A list with elements `abi_version` (the C ABI version, an integer), `go_version`, `tailcat_version`, and `raw`, the full Go build metadata exactly as Go reports it (with Go's own field names, such as `GoVersion`, `Main`, `Deps`, and `Settings`).
#' @examples
#' tailcat_build_info()[c("abi_version", "go_version", "tailcat_version")]
#' @export
tailcat_build_info = function() {
  info = from_json(rtc_value(rtc_build_info(), op = "get build information"))
  go = info$go %||% list()
  list(
    abi_version = rtc_abi_version(),
    go_version = go$GoVersion %||% NA_character_,
    tailcat_version = go$Main$Version %||% NA_character_,
    raw = go
  )
}

#' Cancel a pending asynchronous operation
#'
#' Cancels the operation behind a promise returned by any `_async()` method or function in this package. The promise then rejects with a condition of class `tailcat_canceled` (and `tailcat_error`). Cancellation only ends that operation: the connection, listener, client, or server stays usable, as after a timeout.
#'
#' Cancellation is delivered through the later event loop, like the operation's result, so the promise rejects once the event loop runs. If the operation had already finished, or finishes at the same moment, canceling does nothing and the promise keeps (or receives) its result. Canceling more than once is harmless.
#'
#' For `TailcatConnection$read_all_async()`, which reads in several steps, canceling ends the read in flight and no further reads are started; the condition's `bytes` field gives the number of bytes read before it, which are discarded.
#'
#' Only the promise returned by the `_async()` call can be canceled. A promise derived from it, for example with [promises::then()] or `%...>%`, does not carry the cancellation handle, so keep a reference to the original promise.
#'
#' @param promise A promise returned by an `_async()` method or function of this package.
#' @return `promise`, invisibly.
#' @examples
#' \dontrun{
#' srv = TailcatServer$new()
#' lst = srv$listen(8080)
#' pending = lst$accept_async()
#' tailcat_cancel(pending)
#' promises::catch(pending, function(e) message(class(e)[1]))
#' }
#' @export
tailcat_cancel = function(promise) {
  if (!promises::is.promise(promise)) {
    abort_invalid("{.arg promise} must be a promise returned by an rtailcat {.code _async()} method or function, not {.obj_type_friendly {promise}}.")
  }
  canceler = attr(promise, "rtailcat_cancel")
  if (!is.function(canceler)) {
    abort_invalid(c(
      "{.arg promise} was not returned by an rtailcat {.code _async()} method or function.",
      i = "Promises derived with {.fn promises::then} or a pipe cannot be canceled; cancel the original promise."
    ))
  }
  canceler()
  invisible(promise)
}
