#' Tailcat client
#'
#' @description
#' A tailcat client connects to the [TailcatServer] identified by a secret tailcat address. It can only dial that server. Network startup happens on the first `$dial()`, `$ping()`, or `$disco_ping()`.
#'
#' Blocking methods have an `_async()` counterpart that returns a [promises::promise()]; see [TailcatServer] for how asynchronous results are delivered, for timeouts (including `timeout = 0`), and for the error classes.
#'
#' The address is a secret; printing a client never shows it or the private key, and the client does not keep a copy of the address in R.
#'
#' Once a client is closed, every method other than `$close()`, `$format()`, and `$print()`, and every field other than `$is_closed`, raises a `tailcat_closed` error; nothing is kept from before. A client restored from a saved session is closed, because handles do not survive serialization.
#'
#' A server with an allowlist (`allowed_clients` or `TailcatServer$allow_client()`) does not answer clients that are not on it, so for such a client `$dial()`, `$ping()`, and `$disco_ping()` fail with `tailcat_timeout` once their timeout runs out, rather than with a distinct error.
#'
#' @examples
#' \dontrun{
#' address = readLines("address.txt")
#' cli = TailcatClient$new(address)
#' conn = cli$dial(8080)
#' conn$write("hello\n")
#' conn$close()
#' cli$drain()
#' cli$close()
#' }
#' @export
TailcatClient = R6::R6Class(
  "TailcatClient",
  cloneable = FALSE,
  public = list(
    #' @description Create a client. No network access happens until it is used.
    #' @param address The server's secret tailcat address (a string or a [tailcat_secret]). Surrounding whitespace, such as a trailing newline from a file, is ignored.
    #' @param key Private node key (a string in text encoding, or a `tailcat_keys` object from [tailcat_keygen()]), or `NULL` to generate one. A stable key gives the client a stable public key, for use with `allowed_clients`.
    #' @param derp_map_url URL of a relay map to use instead of the default, or `NULL` to use the `rtailcat.derp_map_url` option (see the section on relay options in [TailcatServer]) or, when that is unset, the default.
    initialize = function(address, key = NULL, derp_map_url = NULL) {
      call = rlang::caller_env()
      config = list(address = check_address(address, call = call))
      config$key = check_key(key, call = call)$private_key
      config$derp_map_url = check_derp_map_url(derp_map_url, call = call)
      result = rtc_client_new(to_json(config))
      if (inherits(result, "rtc_error")) {
        rtc_abort(result, op = "create the client", object = "client", arg = config_arg(result$message, names(config)), call = call)
      }
      private$handle = result
      invisible(self)
    },

    #' @description Connect to a port on the server.
    #' @param port Port number (1 to 65535).
    #' @param network Exactly `"tcp"` (the default) or `"udp"`.
    #' @param timeout Seconds to wait, covering relay registration and the connection; `Inf` waits indefinitely and `0` polls.
    #' @return A [TailcatConnection].
    dial = function(port, network = c("tcp", "udp"), timeout = 30) {
      port = check_port(port, allow_zero = FALSE)
      code = network_code(network)
      timeout = check_timeout(timeout)
      h = private$check(rtc_client_dial(private$handle, port, code, timeout, NULL), paste0("dial port ", port), timeout, hint = unanswered)
      TailcatConnection$new(h, self, code)
    },

    #' @description Asynchronous version of `$dial()`.
    #' @param port Port number (1 to 65535).
    #' @param network Exactly `"tcp"` (the default) or `"udp"`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with a [TailcatConnection].
    dial_async = function(port, network = c("tcp", "udp"), timeout = 30) {
      port = check_port(port, allow_zero = FALSE)
      code = network_code(network)
      timeout = check_timeout(timeout)
      private$promise(
        function(cb) rtc_client_dial(private$handle, port, code, timeout, cb),
        function(h) TailcatConnection$new(h, self, code),
        paste0("dial port ", port), timeout, hint = unanswered
      )
    },

    #' @description Measure the round-trip time to the server through the relay.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return The latency in seconds (a double). tailcat reports whole milliseconds, so the resolution is 0.001 and a ping faster than a millisecond reads as `0`. This differs from tailcat's C ABI (`r tailcat_header_link()`), which returns the milliseconds; seconds match `$disco_ping()` and the timeouts.
    ping = function(timeout = 30) {
      timeout = check_timeout(timeout)
      ping_seconds(private$check(rtc_client_ping(private$handle, timeout, NULL), "ping the server", timeout, hint = unanswered))
    },

    #' @description Asynchronous version of `$ping()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the latency in seconds.
    ping_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_client_ping(private$handle, timeout, cb), ping_seconds, "ping the server", timeout, hint = unanswered)
    },

    #' @description Send a discovery ping, which also triggers direct path discovery.
    #' @param timeout Seconds to wait; use a finite value since discovery may otherwise wait indefinitely.
    #' @return A list with `latency` (seconds), `endpoint` (the direct path, or `""` when relayed), `relay_region_id`, and `relay_region_code` (the relay region the ping went through).
    disco_ping = function(timeout = 30) {
      timeout = check_timeout(timeout)
      parse_disco_ping(private$check(rtc_client_disco_ping(private$handle, timeout, NULL), "send a discovery ping", timeout, hint = unanswered))
    },

    #' @description Asynchronous version of `$disco_ping()`.
    #' @param timeout Seconds to wait.
    #' @return A promise resolving with the discovery ping list.
    disco_ping_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_client_disco_ping(private$handle, timeout, cb), parse_disco_ping, "send a discovery ping", timeout, hint = unanswered)
    },

    #' @description Information about the client.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A list with `public_key`.
    info = function(timeout = 30) {
      timeout = check_timeout(timeout)
      parse_info(private$check(rtc_info(private$handle, timeout, NULL), "get the client's information", timeout))
    },

    #' @description Asynchronous version of `$info()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the info list.
    info_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_info(private$handle, timeout, cb), parse_info, "get the client's information", timeout)
    },

    #' @description Wait for TCP shutdown traffic to finish. Call it after closing connections (or reaching end of stream) and before closing the client or exiting R, so the server sees a clean end of stream.
    #' @param timeout Seconds to wait. `Inf` is accepted but waits as long as shutdown takes, which can be indefinitely when a peer has gone away, so a finite value is recommended.
    #' @return The client, invisibly.
    drain = function(timeout = 5) {
      timeout = check_timeout(timeout)
      private$check(rtc_drain(private$handle, timeout, NULL), "drain the client", timeout)
      invisible(self)
    },

    #' @description Asynchronous version of `$drain()`.
    #' @param timeout Seconds to wait; as for `$drain()`, a finite value is recommended.
    #' @return A promise resolving with the client.
    drain_async = function(timeout = 5) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_drain(private$handle, timeout, cb), function(x) self, "drain the client", timeout)
    },

    #' @description Close the client and all of its connections. Closing twice is harmless. Closing tears the client down immediately, so the server may not see the end of its streams until its own reads time out. To give the server a clean end of stream, close the connections first and pass `drain`, which waits for their shutdown traffic before closing (see `$drain()`).
    #' @param drain Seconds to wait for TCP shutdown traffic before closing, as for `$drain()`; `0` (the default) closes at once. A drain that times out or fails does not prevent the close and is not reported.
    #' @return The client, invisibly.
    close = function(drain = 0) {
      drain = check_timeout(drain, "drain")
      if (drain > 0 && !self$is_closed) {
        on.exit(rtc_close(private$handle))
        rtc_drain(private$handle, drain, NULL)
      }
      rtc_close(private$handle)
      invisible(self)
    },

    #' @description Format a summary, the lines that `$print()` shows. The address and private key are never shown. A closed client shows only its state.
    #' @param ... Ignored.
    #' @return A character vector.
    format = function(...) {
      lines = "<TailcatClient>"
      if (self$is_closed) {
        lines = c(lines, paste0("  state:      ", state_label(TRUE, handle = private$handle)))
      } else {
        key = safely(parse_info(rtc_value(rtc_info(private$handle, 5, NULL)))$public_key)
        lines = c(
          lines,
          paste0("  state:      ", state_label(FALSE)),
          paste0("  public_key: ", key %||% "<unknown>"),
          "  address:    <redacted>"
        )
      }
      lines
    },

    #' @description Print the summary from `$format()`.
    #' @param ... Ignored.
    print = function(...) {
      cat(self$format(...), sep = "\n")
      invisible(self)
    }
  ),
  active = list(
    #' @field public_key The client's public key, for `TailcatServer$allow_client()`. It is fetched from tailcat on each access.
    public_key = function(value) {
      call = field_call("cl", "public_key")
      if (!missing(value)) {
        abort_invalid("{.field public_key} is read-only.", call = call)
      }
      parse_info(private$check(rtc_info(private$handle, 30, NULL), "get the client's public key", 30, call = call))$public_key
    },
    #' @field is_closed `TRUE` once the client has been closed.
    is_closed = function(value) {
      if (!missing(value)) {
        abort_invalid("{.field is_closed} is read-only.", call = field_call("cl", "is_closed"))
      }
      rtc_is_closed(private$handle)
    }
  ),
  private = list(
    handle = NULL,
    check = function(x, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_value(x, op = op, object = "client", timeout = timeout, handle = private$handle, ..., call = call)
    },
    promise = function(start, transform, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_promise(start, transform, op = op, object = "client", timeout = timeout, handle = private$handle, ..., call = call)
    }
  )
)

unanswered = c(i = "A server that is offline, or that does not admit this client (see `allowed_clients`), does not answer; the call then runs out its timeout.")

ping_seconds = function(ms) {
  ms / 1000
}

parse_json = function(json) {
  tailcat_fields(from_json(json))
}
