#' Tailcat server
#'
#' @description
#' A tailcat server registers with a public relay and publishes a secret, shareable address. Clients holding the address can dial the ports the server listens on, over TCP or UDP, without accounts or port forwarding.
#'
#' Blocking methods have an `_async()` counterpart that returns a [promises::promise()] resolving with the same value, or rejecting with the same condition. Asynchronous results are delivered by the later event loop, so they only arrive while R is idle at the console, inside Shiny or httpuv, or while you call [later::run_now()]. The result goes to the loop that was current when the operation started, so an operation started inside [later::with_temp_loop()] or [later::with_loop()] completes while that loop runs. If that loop is destroyed before the operation completes, the result is delivered on the global loop instead (checked about once a second while such operations are pending). A pending asynchronous operation can be canceled with [tailcat_cancel()].
#'
#' Blocking methods can be interrupted (Ctrl-C or Esc), which cancels the operation. If the operation completes at the same moment, its result is returned and that interrupt is dropped rather than losing data such as bytes just read.
#'
#' The address and the private and pre-shared keys are secrets: anyone with the address can connect. Printing a server never shows them. `$address` and the `address` element of `$info()` are [tailcat_secret] strings, which print as `<redacted>` but otherwise behave like the full address (for example with `writeLines()` or `as.character()`). The server does not keep the address in an R field, so saving the server object (for example with `saveRDS()` or `save.image()`) does not write the address to disk. Handles do not survive serialization: a server restored from a saved session is closed.
#'
#' Once a server is closed, every method other than `$close()`, `$format()`, and `$print()`, and every field other than `$is_closed`, raises a `tailcat_closed` error; nothing is kept from before.
#'
#' @section Timeouts:
#' Every blocking method and function of this package takes a `timeout` in seconds. `Inf` waits indefinitely. `timeout = 0` is a non-blocking poll: the call returns what is available right away (for example data already received, or a connection already waiting) and otherwise raises `tailcat_timeout` at once. This differs from tailcat's C ABI (`r tailcat_header_link()`), where a zero timeout is an already expired deadline that fails without trying; rtailcat gives a poll a deadline of a few milliseconds instead. A poll waits for an operation started before it in the same direction of a connection only for that short time.
#'
#' A timeout ends only that call: the server, listener, client, or connection stays usable.
#'
#' @section Errors:
#' Errors are conditions with class `tailcat_error` and one subclass that says what went wrong. Each also carries an integer `status` (the status code of the C ABI) and `bytes`, the number of bytes transferred before the error (for reads and writes; otherwise `0`). The message starts with a one-line summary; a line starting `tailcat:` gives tailcat's own description when it has one.
#'
#' | `status` | Class                      | Meaning                                                     |
#' | -------- | -------------------------- | ----------------------------------------------------------- |
#' | 1        | `tailcat_invalid_argument` | An argument is invalid                                      |
#' | 2        | `tailcat_closed`           | The object, or the client or server that owns it, is closed |
#' | 3        | `tailcat_timeout`          | The timeout ran out                                         |
#' | 4        | `tailcat_canceled`         | The operation was canceled with [tailcat_cancel()]          |
#' | 5        | `tailcat_failure`          | Anything else, including calls made in the wrong state      |
#'
#' Branch on the class (for example with `tryCatch(..., tailcat_timeout = function(e) ...)`) or the `status`, not on the message, whose wording may change.
#'
#' @section Operations in flight:
#' Every operation that can block (each method or function with a `timeout`, and fields such as `$address` that ask tailcat), synchronous or asynchronous, holds its own operating system thread from the moment it starts until it ends, including while it waits its turn behind other reads or writes on a connection. The option `rtailcat.max_operations` caps how many such operations may be in flight in the R process at once. It must be a single positive whole number, or `Inf` for no cap, and defaults to 1024, which stays well below the per-process thread limits of macOS (about 6,000) and typical Linux systems and the 10,000 threads at which the Go runtime ends the process. The option is read each time an operation starts. An operation started when the cap is reached fails at once with a `tailcat_failure` error that names the option and gives the limit, without affecting the operations already in flight; once some of them finish or are canceled, new operations work again. If the option is set to an invalid value, every such operation fails with a `tailcat_failure` error saying so.
#'
#' @examples
#' \dontrun{
#' srv = TailcatServer$new()
#' lst = srv$listen(8080)
#' srv$address # share this with the client, it is a secret
#' conn = lst$accept()
#' conn$read()
#' srv$close()
#' }
#' @export
TailcatServer = R6::R6Class(
  "TailcatServer",
  cloneable = FALSE,
  public = list(
    #' @description Create a server. Nothing is sent over the network until the server is started (by `$start()` or `$listen()`). Only arguments that are not `NULL` are passed to tailcat.
    #' @param key Private node key: a string in tailcat's text encoding, a `tailcat_keys` object from [tailcat_keygen()], or `NULL` to generate one. A `tailcat_keys` object also supplies the pre-shared key, unless `preshared_key` is given. Keep the keys to reuse an address across restarts.
    #' @param preshared_key Pre-shared key (text encoding), or `NULL` to generate one (or take it from `key`).
    #' @param region_id Integer relay region to register in, or `NULL` to choose automatically.
    #' @param region A relay region definition, as a list or a JSON string, to use instead of the public relay map. Field names may be the snake_case names used by [tailcat_address_parse()] (`region_id`, `region_code`, `nodes`, and within each node `name`, `host_name`, `ipv4`, `relay_port`, and so on) or the PascalCase names of Tailscale's `DERPRegion` type (`RegionID`, `Nodes`, `HostName`, `DERPPort`, and so on).
    #' @param derp_map_url URL of a relay map to use instead of the default.
    #' @param allowed_clients Character vector of client public keys. If given, only these clients may connect; otherwise anyone with the address may.
    #' @param udp_idle_timeout Seconds after which an idle UDP flow is dropped, or `NULL` for the default.
    initialize = function(key = NULL, preshared_key = NULL, region_id = NULL, region = NULL, derp_map_url = NULL, allowed_clients = NULL, udp_idle_timeout = NULL) {
      call = rlang::caller_env()
      key = check_key(key, call = call)
      config = list()
      config$key = key$private_key
      config$preshared_key = check_string(preshared_key, "preshared_key", null_ok = TRUE, call = call) %||% key$preshared_key
      if (!is.null(region_id)) {
        if (!is.numeric(region_id) || length(region_id) != 1 || is.na(region_id) || region_id != trunc(region_id) || region_id < 0 || region_id > .Machine$integer.max) {
          max_id = .Machine$integer.max
          abort_invalid("{.arg region_id} must be a single non-negative integer no larger than {max_id}.", call = call)
        }
        config$region_id = as.integer(region_id)
      }
      if (!is.null(region)) {
        config$region = check_region(region, call = call)
      }
      config$derp_map_url = check_string(derp_map_url, "derp_map_url", null_ok = TRUE, call = call)
      if (!is.null(allowed_clients)) {
        if (!is.character(allowed_clients) || anyNA(allowed_clients)) {
          abort_invalid("{.arg allowed_clients} must be a character vector of public keys.", call = call)
        }
        config$allowed_clients = I(enc2utf8(allowed_clients))
      }
      if (!is.null(udp_idle_timeout)) {
        config$udp_idle_timeout = check_timeout(udp_idle_timeout, "udp_idle_timeout", call = call)
        if (is.infinite(config$udp_idle_timeout)) {
          abort_invalid("{.arg udp_idle_timeout} must be finite.", call = call)
        }
      }
      json = if (length(config) == 0) "{}" else to_json(config)
      result = rtc_server_new(json)
      if (inherits(result, "rtc_error")) {
        rtc_abort(result, op = "create the server", object = "server", arg = config_arg(result$message, names(config)), call = call)
      }
      private$handle = result
      invisible(self)
    },

    #' @description Register with the relay so the server has an address. Calling it again is harmless.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls (see the section on timeouts).
    #' @return The server, invisibly.
    start = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$check(rtc_server_start(private$handle, timeout, NULL), "start the server", timeout)
      invisible(self)
    },

    #' @description Asynchronous version of `$start()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the server.
    start_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_server_start(private$handle, timeout, cb), function(x) self, "start the server", timeout)
    },

    #' @description Listen on a port, starting the server first if needed.
    #' @param port Port number; `0` picks a free port (see the listener's `$port`).
    #' @param network Exactly `"tcp"` (the default) or `"udp"`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A [TailcatListener].
    listen = function(port = 0L, network = c("tcp", "udp"), timeout = 30) {
      port = check_port(port)
      code = network_code(network)
      timeout = check_timeout(timeout)
      h = private$check(rtc_server_listen(private$handle, port, code, timeout, NULL), listen_op(port), timeout)
      TailcatListener$new(h, self, code)
    },

    #' @description Asynchronous version of `$listen()`.
    #' @param port Port number; `0` picks a free port.
    #' @param network Exactly `"tcp"` (the default) or `"udp"`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with a [TailcatListener].
    listen_async = function(port = 0L, network = c("tcp", "udp"), timeout = 30) {
      port = check_port(port)
      code = network_code(network)
      timeout = check_timeout(timeout)
      private$promise(
        function(cb) rtc_server_listen(private$handle, port, code, timeout, cb),
        function(h) TailcatListener$new(h, self, code),
        listen_op(port), timeout
      )
    },

    #' @description Add a client public key to the allowlist. Once the list has an entry, only listed clients can register; existing connections are not affected.
    #' @param public_key A client public key, for example `TailcatClient$public_key`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return The server, invisibly.
    allow_client = function(public_key, timeout = 30) {
      public_key = check_string(public_key, "public_key")
      timeout = check_timeout(timeout)
      private$check(rtc_server_allow_client(private$handle, public_key, timeout, NULL), "add the client to the allowlist", timeout, arg = "public_key")
      invisible(self)
    },

    #' @description Asynchronous version of `$allow_client()`.
    #' @param public_key A client public key.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the server.
    allow_client_async = function(public_key, timeout = 30) {
      public_key = check_string(public_key, "public_key")
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_server_allow_client(private$handle, public_key, timeout, cb), function(x) self, "add the client to the allowlist", timeout, arg = "public_key")
    },

    #' @description Information about the started server.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A list with `address` (a [tailcat_secret]), `ip` (the server's own IP address on the tailcat network, without a port), and `public_key`. Errors if the server has not started.
    info = function(timeout = 30) {
      timeout = check_timeout(timeout)
      server_info(private$check(rtc_info(private$handle, timeout, NULL), "get the server's information", timeout, invalid_headline = not_started))
    },

    #' @description Asynchronous version of `$info()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the info list.
    info_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_info(private$handle, timeout, cb), server_info, "get the server's information", timeout, invalid_headline = not_started)
    },

    #' @description Wait for TCP shutdown traffic to finish. Call it after closing connections and before closing the server or exiting R, so that peers see a clean end of stream.
    #' @param timeout Seconds to wait. `Inf` is accepted but waits as long as shutdown takes, which can be indefinitely when a peer has gone away, so a finite value is recommended.
    #' @return The server, invisibly.
    drain = function(timeout = 5) {
      timeout = check_timeout(timeout)
      private$check(rtc_drain(private$handle, timeout, NULL), "drain the server", timeout)
      invisible(self)
    },

    #' @description Asynchronous version of `$drain()`.
    #' @param timeout Seconds to wait; as for `$drain()`, a finite value is recommended.
    #' @return A promise resolving with the server.
    drain_async = function(timeout = 5) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_drain(private$handle, timeout, cb), function(x) self, "drain the server", timeout)
    },

    #' @description Close the server, its listeners, and all of its connections. Pending operations on them end with a `tailcat_closed` error. Closing twice is harmless. Closing tears the server down immediately, so clients may not see the end of their streams until their own reads time out; to give clients a clean end of stream, close the connections and call `$drain()` first.
    #' @return The server, invisibly.
    close = function() {
      rtc_close(private$handle)
      invisible(self)
    },

    #' @description Format a summary, the lines that `$print()` shows. The address and keys are never shown. A closed server shows only its state.
    #' @param ... Ignored.
    #' @return A character vector.
    format = function(...) {
      lines = "<TailcatServer>"
      closed = self$is_closed
      if (closed) {
        lines = c(lines, paste0("  state:      ", state_label(TRUE, handle = private$handle)))
      } else {
        info = rtc_info(private$handle, 5, NULL)
        started = !inherits(info, "rtc_error")
        key = if (started) safely(server_info(info)$public_key) else NULL
        lines = c(
          lines,
          paste0("  state:      ", state_label(FALSE, started)),
          paste0("  public_key: ", if (started) key %||% "<unknown>" else "<unknown until started>"),
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
    #' @field address The secret tailcat address to give to clients, as a [tailcat_secret]. It is fetched from tailcat on each access (a quick local call) rather than stored in R. Errors if the server has not started.
    address = function(value) {
      private$read_only("address", value)
      private$field_info("address", "get the server's address")$address
    },
    #' @field public_key The server's public key, or `NA` before the server has started.
    public_key = function(value) {
      private$read_only("public_key", value)
      info = private$field_info("public_key", "get the server's public key", started_only = FALSE)
      if (is.null(info)) NA_character_ else info$public_key
    },
    #' @field is_started `TRUE` once the server has started (registered with the relay), `FALSE` before.
    is_started = function(value) {
      private$read_only("is_started", value)
      !is.null(private$field_info("is_started", "check whether the server has started", started_only = FALSE))
    },
    #' @field is_closed `TRUE` once the server has been closed.
    is_closed = function(value) {
      private$read_only("is_closed", value)
      rtc_is_closed(private$handle)
    }
  ),
  private = list(
    handle = NULL,
    check = function(x, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_value(x, op = op, object = "server", timeout = timeout, handle = private$handle, ..., call = call)
    },
    promise = function(start, transform, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_promise(start, transform, op = op, object = "server", timeout = timeout, handle = private$handle, ..., call = call)
    },
    read_only = function(field, value) {
      if (!missing(value)) {
        abort_invalid("{.field {field}} is read-only.", call = field_call("srv", field))
      }
    },
    # Fields are fetched from tailcat on every access, so a closed server has
    # none. NULL means not started, when started_only is FALSE.
    field_info = function(field, op, started_only = TRUE) {
      result = rtc_info(private$handle, 30, NULL)
      if (!started_only && inherits(result, "rtc_error") && identical(result$status, 1L)) {
        return(NULL)
      }
      server_info(private$check(result, op, 30, invalid_headline = not_started, call = field_call("srv", field)))
    }
  )
)

not_started = "The server has not started; call `$start()` or `$listen()` first."

server_info = function(json) {
  info = parse_info(json)
  names(info)[names(info) == "local_address"] = "ip"
  info
}

listen_op = function(port) {
  if (port == 0) "listen on a free port" else paste0("listen on port ", port)
}

# Active bindings cannot see the expression that read them, so errors from
# fields name the field on a conventional object name.
field_call = function(object, field) {
  call("$", as.name(object), as.name(field))
}

check_key = function(key, call = parent.frame()) {
  if (is.null(key)) {
    return(list())
  }
  if (inherits(key, "tailcat_keys")) {
    parts = if (is.list(key)) unclass(key)[c("private_key", "public_key", "preshared_key")] else list()
    valid = length(parts) == 3 && all(vapply(parts, function(x) {
      x = reveal(x)
      is.character(x) && length(x) == 1 && !is.na(x) && nzchar(x)
    }, logical(1)))
    if (!valid) {
      abort_invalid(c(
        "{.arg key} is a {.cls tailcat_keys} object without a complete set of keys.",
        i = "Create one with {.fn tailcat_keygen}."
      ), call = call)
    }
    return(list(private_key = enc2utf8(reveal(parts$private_key)), preshared_key = enc2utf8(reveal(parts$preshared_key))))
  }
  list(private_key = check_string(key, "key", call = call))
}

check_region = function(region, call = parent.frame()) {
  if (is.character(region) && length(region) == 1 && !is.na(region)) {
    region = tryCatch(
      jsonlite::fromJSON(region, simplifyVector = FALSE),
      error = function(e) abort_invalid("{.arg region} is not valid JSON.", call = call)
    )
  }
  if (!is.list(region)) {
    abort_invalid("{.arg region} must be a list or a JSON string.", call = call)
  }
  upstream_fields(region)
}
