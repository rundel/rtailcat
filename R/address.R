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
  tailcat_fields(from_json(rtc_value(
    rtc_address_parse(address),
    op = "parse the address",
    arg = "address"
  )))
}

#' Embed relay details in a tailcat address
#'
#' Returns a self-contained version of `address` with the relay (DERP) details embedded, fetching the relay map if needed. A resolved address avoids relay map discovery when a client connects, although connecting still needs network access. The result is a secret, like the input.
#'
#' @inheritParams tailcat_address_parse
#' @param relay_map_url URL of a relay map to use instead of the default, or `NULL` to use the `rtailcat.relay_map_url` option (see the section on relay options in [TailcatServer]) or, when that is unset, the default.
#' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls (see the section on timeouts in [TailcatServer]).
#' @return `tailcat_address_resolve()` returns the resolved address as a [tailcat_secret]. `tailcat_address_resolve_async()` returns a [promises::promise()] that resolves with it.
#' @export
tailcat_address_resolve = function(address, relay_map_url = NULL, timeout = 30) {
  address = check_address(address)
  relay_map_url = check_relay_map_url(relay_map_url)
  timeout = check_timeout(timeout)
  new_secret(rtc_value(
    rtc_address_resolve(address, relay_map_url, timeout, NULL),
    op = "resolve the address",
    arg = "address",
    timeout = timeout
  ))
}

#' @rdname tailcat_address_resolve
#' @export
tailcat_address_resolve_async = function(address, relay_map_url = NULL, timeout = 30) {
  address = check_address(address)
  relay_map_url = check_relay_map_url(relay_map_url)
  timeout = check_timeout(timeout)
  rtc_promise(
    \(callback) rtc_address_resolve(address, relay_map_url, timeout, callback),
    new_secret,
    op = "resolve the address",
    arg = "address",
    timeout = timeout
  )
}
