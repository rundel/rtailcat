#' Tailcat connection
#'
#' @description
#' A TCP stream or connected UDP flow between a [TailcatClient] and a [TailcatServer]. Connections are created by `TailcatClient$dial()` and `TailcatListener$accept()`, not directly.
#'
#' For TCP, reads may return fewer bytes than requested and `$read()` returns `NULL` at end of stream. For UDP, each read returns one datagram (possibly `raw(0)`) and each write sends one datagram of at most 1232 bytes.
#'
#' One read and one write may be in flight at the same time (for example a pending `$read_async()` while writing). Further operations in the same direction wait their turn and run in the order they were started, for synchronous and asynchronous calls alike, so several `$write_async()` calls send their data in call order and several `$read_async()` calls receive consecutive chunks of the stream in call order. The wait counts toward each operation's timeout, and canceling or timing out an operation that is still waiting ends it without affecting the others.
#'
#' `$client` or `$server` (the other is `NULL`) gives the object that owns the connection, the client that dialed it or the server whose listener accepted it.
#'
#' Once the connection, or the client or server that owns it, is closed, every method other than `$close()`, `$format()`, and `$print()`, and every field other than `$is_closed`, `$client`, and `$server`, raises a `tailcat_closed` error; nothing is kept from before. Timeouts (including `timeout = 0`, a poll) and errors are described in [TailcatServer].
#'
#' Because of an upstream tailcat bug, `$info()` (and so `$local_address` and `$remote_address`) fails with `tailcat_failure`, and the Go runtime prints a stack trace to standard error, on a TCP connection whose two directions have both been shut down (both sides called `$close_write()`). `$print()` and `$format()` avoid this by leaving the endpoints out once `$close_write()` has succeeded on the connection.
#'
#' @examples
#' \dontrun{
#' conn = TailcatClient$new(address)$dial(8080)
#' conn$write("ping")
#' conn$close_write()
#' conn$read_all(timeout = 10, as = "text")
#' }
#' @export
TailcatConnection = R6::R6Class(
  "TailcatConnection",
  cloneable = FALSE,
  public = list(
    #' @description Internal constructor; use `TailcatClient$dial()` or `TailcatListener$accept()`.
    #' @param handle Native connection handle.
    #' @param owner The owning [TailcatClient] or [TailcatServer].
    #' @param network Integer network code.
    initialize = function(handle, owner, network) {
      if (!inherits(handle, "rtc_connection") || !is_tailcat_object(owner, c("TailcatClient", "TailcatServer"))) {
        abort_invalid("Connections are created by {.code TailcatClient$dial()} or {.code TailcatListener$accept()}.")
      }
      private$handle = handle
      private$owner = owner
      private$network_code = as.integer(network)
      invisible(self)
    },

    #' @description Read up to `n` bytes (TCP) or one datagram (UDP, truncated to `n` bytes). One call returns at most 65536 bytes whatever the value of `n` (TCP reads may return less than requested anyway, and UDP datagrams are much smaller), so loop, or use `$read_all()`, to read more. A timeout ends only this read; the connection stays usable. With `timeout = 0` the read returns data (or the end of stream) that has already arrived, and otherwise raises `tailcat_timeout` at once. A TCP read returns whatever has arrived, so with `as = "text"` a multibyte UTF-8 character can be split across two reads; for multibyte text use `$read_all()`, or read raw bytes and convert them once. On UDP, `n = 0` is not supported: because of an upstream tailcat bug it fails and the datagram is lost.
    #' @param n Maximum number of bytes to return (at most 65536 are returned).
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @param as Exactly `"raw"` (the default) to return a raw vector, or `"text"` to return a single string marked as UTF-8 (the bytes are not checked for valid UTF-8). Data containing NUL bytes cannot be returned as text and raises a `tailcat_invalid_argument` error; the data is consumed, so read binary data with `as = "raw"`.
    #' @return A raw vector or a string, or `NULL` at TCP end of stream.
    read = function(n = 65536L, timeout = Inf, as = c("raw", "text")) {
      n = check_count(n)
      timeout = check_timeout(timeout)
      as = check_as(as)
      convert_read(private$check(rtc_conn_read(private$handle, n, timeout, NULL), "read", timeout), as)
    },

    #' @description Asynchronous version of `$read()`.
    #' @param n Maximum number of bytes to return.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @param as `"raw"` or `"text"`, as for `$read()`.
    #' @return A promise resolving with a raw vector or a string, or `NULL` at TCP end of stream.
    read_async = function(n = 65536L, timeout = Inf, as = c("raw", "text")) {
      n = check_count(n)
      timeout = check_timeout(timeout)
      as = check_as(as)
      call = error_call(rlang::current_env())
      private$promise(function(cb) rtc_conn_read(private$handle, n, timeout, cb), function(x) convert_read(x, as, call), "read", timeout)
    },

    #' @description Read until the peer ends the stream (TCP only). On timeout or error the condition's `bytes` field gives the number of bytes read before it; those bytes are discarded. With `timeout = 0` it returns only if the whole stream, including its end, has already arrived.
    #' @param timeout Overall seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @param as Exactly `"raw"` (the default) to return a raw vector, or `"text"` to return a single string marked as UTF-8 (`""` for an empty stream). See `$read()` for NUL bytes.
    #' @param max_bytes The most bytes to accept, a single non-negative whole number or `Inf` (the default) for no limit. If the stream is longer, reading stops after `max_bytes + 1` bytes and a `tailcat_failure` error is raised whose `bytes` field is the number of bytes read (`max_bytes + 1`). Those bytes are discarded, but the connection stays open and usable: the rest of the stream can still be read, or the connection closed.
    #' @return A raw vector or a string.
    read_all = function(timeout = Inf, as = c("raw", "text"), max_bytes = Inf) {
      private$require_tcp("read_all")
      timeout = check_timeout(timeout)
      deadline = deadline_from(timeout)
      as = check_as(as)
      max_bytes = check_max_bytes(max_bytes)
      chunks = list()
      total = 0
      repeat {
        result = rtc_conn_read(private$handle, read_all_chunk(max_bytes, total), remaining_until(deadline), NULL)
        if (is.null(result)) {
          break
        }
        if (inherits(result, "rtc_error")) {
          private$check(result, "read to the end of the stream", timeout, bytes = byte_total(total))
        }
        chunks[[length(chunks) + 1L]] = result
        total = total + length(result)
        if (total > max_bytes) {
          tailcat_abort(5L, headline = too_long_headline(max_bytes), bullets = too_long_bullets, bytes = byte_total(total))
        }
      }
      convert_read(do.call(c, c(list(raw(0)), chunks)), as)
    },

    #' @description Asynchronous version of `$read_all()`. Canceling the promise with [tailcat_cancel()] ends the read in flight and starts no further reads.
    #' @param timeout Overall seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @param as `"raw"` or `"text"`, as for `$read_all()`.
    #' @param max_bytes The most bytes to accept, as for `$read_all()`; a longer stream rejects the promise with a `tailcat_failure` error.
    #' @return A promise resolving with a raw vector or a string.
    read_all_async = function(timeout = Inf, as = c("raw", "text"), max_bytes = Inf) {
      private$require_tcp("read_all_async")
      timeout = check_timeout(timeout)
      deadline = deadline_from(timeout)
      as = check_as(as)
      max_bytes = check_max_bytes(max_bytes)
      call = error_call(rlang::current_env())
      handle = private$handle
      fail = function(result, total) {
        rtc_condition(result, op = "read to the end of the stream", object = "connection", timeout = timeout, handle = handle, bytes = byte_total(total), call = call)
      }
      state = new.env(parent = emptyenv())
      state$canceled = FALSE
      state$cancel = NULL
      p = promises::promise(function(resolve, reject) {
        chunks = list()
        total = 0
        step = function() {
          if (state$canceled) {
            reject(fail(canceled_error(), total))
            return(invisible())
          }
          state$cancel = rtc_conn_read(handle, read_all_chunk(max_bytes, total), remaining_until(deadline), rtc_callback(
            function(result) {
              if (is.null(result)) {
                resolve(convert_read(do.call(c, c(list(raw(0)), chunks)), as, call))
              } else if (inherits(result, "rtc_error")) {
                reject(fail(result, total))
              } else {
                chunks[[length(chunks) + 1L]] <<- result
                total <<- total + length(result)
                if (total > max_bytes) {
                  reject(tailcat_condition(5L, headline = too_long_headline(max_bytes), bullets = too_long_bullets, bytes = byte_total(total), call = call))
                } else {
                  step()
                }
              }
            },
            on_error = reject
          ))
          invisible()
        }
        step()
      })
      with_canceler(p, function() {
        state$canceled = TRUE
        if (!is.null(state$cancel)) {
          rtc_cancel(state$cancel)
        }
      })
    },

    #' @description Write all of `data`. On timeout or error the condition's `bytes` field gives the number of bytes already sent.
    #' @param data A raw vector, or a character vector which is pasted together without separators and sent as UTF-8.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls (sends what can be sent at once).
    #' @return The number of bytes written (an integer, or a double beyond the integer range), invisibly.
    write = function(data, timeout = Inf) {
      data = private$payload(data)
      timeout = check_timeout(timeout)
      invisible(private$check(rtc_conn_write(private$handle, data, timeout, NULL), "write", timeout))
    },

    #' @description Asynchronous version of `$write()`.
    #' @param data A raw or character vector.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the number of bytes written.
    write_async = function(data, timeout = Inf) {
      data = private$payload(data)
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_conn_write(private$handle, data, timeout, cb), identity, "write", timeout)
    },

    #' @description Half-close a TCP connection: tell the peer there is nothing more to send, while still being able to read its reply.
    #' @param timeout Seconds to wait for pending writes; `Inf` waits indefinitely and `0` polls.
    #' @return The connection, invisibly.
    close_write = function(timeout = 30) {
      private$require_tcp("close_write")
      timeout = check_timeout(timeout)
      private$check(rtc_conn_close_write(private$handle, timeout, NULL), "close the connection for writing", timeout)
      invisible(self)
    },

    #' @description Asynchronous version of `$close_write()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the connection.
    close_write_async = function(timeout = 30) {
      private$require_tcp("close_write_async")
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_conn_close_write(private$handle, timeout, cb), function(x) self, "close the connection for writing", timeout)
    },

    #' @description Check without waiting whether a TCP read would return immediately (buffered data, end of stream, or a pending error). Intended for checking idle connections, not as a readiness loop.
    #' @return `TRUE` or `FALSE`.
    readable = function() {
      private$require_tcp("readable")
      private$check(rtc_conn_readable(private$handle), "check whether the connection is readable")
    },

    #' @description Information about the connection. Because of an upstream tailcat bug it fails with `tailcat_failure` once both directions of a TCP connection have been shut down.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A list with `local_address`, `remote_address`, and `network`.
    info = function(timeout = 30) {
      timeout = check_timeout(timeout)
      parse_info(private$check(rtc_info(private$handle, timeout, NULL), "get the connection's information", timeout))
    },

    #' @description Asynchronous version of `$info()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the info list.
    info_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_info(private$handle, timeout, cb), parse_info, "get the connection's information", timeout)
    },

    #' @description Close the connection. Pending reads and writes end with a `tailcat_closed` error. Closing twice is harmless.
    #' @return The connection, invisibly.
    close = function() {
      rtc_close(private$handle)
      invisible(self)
    },

    #' @description Format a summary, the lines that `$print()` shows. An open connection shows its local and remote endpoints on the tailcat network (not secrets); they are left out when the connection is closed, when tailcat cannot report them, and once `$close_write()` has succeeded on it, because asking tailcat after both sides have shut down their writes triggers an upstream bug that prints a Go stack trace.
    #' @param ... Ignored.
    #' @return A character vector.
    format = function(...) {
      closed = self$is_closed
      side = if (inherits(private$owner, "TailcatClient")) "client (dialed)" else "server (accepted)"
      lines = c(
        "<TailcatConnection>",
        paste0("  state:   ", state_label(closed, handle = private$handle)),
        paste0("  network: ", network_name(private$network_code)),
        paste0("  side:    ", side)
      )
      if (!closed && !rtc_conn_write_shut(private$handle)) {
        info = safely(parse_info(rtc_value(rtc_info(private$handle, 5, NULL))))
        if (!is.null(info$local_address) && !is.null(info$remote_address)) {
          lines = c(lines, paste0("  local:   ", info$local_address), paste0("  remote:  ", info$remote_address))
        }
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
    #' @field local_address The local endpoint as `"host:port"` on the tailcat network. It is fetched from tailcat on each access.
    local_address = function(value) {
      private$field_info("local_address", value)$local_address
    },
    #' @field remote_address The peer's endpoint as `"host:port"` on the tailcat network. It is fetched from tailcat on each access.
    remote_address = function(value) {
      private$field_info("remote_address", value)$remote_address
    },
    #' @field network `"tcp"` or `"udp"`.
    network = function(value) {
      private$read_only("network", value)
      if (self$is_closed) {
        abort_closed("connection", private$handle, call = field_call("conn", "network"))
      }
      network_name(private$network_code)
    },
    #' @field client The [TailcatClient] that dialed the connection, or `NULL` for an accepted connection. Like `$server`, it keeps working after the connection is closed.
    client = function(value) {
      private$read_only("client", value)
      if (inherits(private$owner, "TailcatClient")) private$owner else NULL
    },
    #' @field server The [TailcatServer] whose listener accepted the connection, or `NULL` for a dialed connection. It keeps working after the connection is closed.
    server = function(value) {
      private$read_only("server", value)
      if (inherits(private$owner, "TailcatServer")) private$owner else NULL
    },
    #' @field is_closed `TRUE` once the connection, or the client or server that owns it, has been closed.
    is_closed = function(value) {
      private$read_only("is_closed", value)
      rtc_is_closed(private$handle) || private$owner$is_closed
    }
  ),
  private = list(
    handle = NULL,
    owner = NULL,
    network_code = NULL,
    check = function(x, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_value(x, op = op, object = "connection", timeout = timeout, handle = private$handle, ..., call = call)
    },
    promise = function(start, transform, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_promise(start, transform, op = op, object = "connection", timeout = timeout, handle = private$handle, ..., call = call)
    },
    read_only = function(field, value) {
      if (!missing(value)) {
        abort_invalid("{.field {field}} is read-only.", call = field_call("conn", field))
      }
    },
    field_info = function(field, value) {
      private$read_only(field, value)
      parse_info(private$check(rtc_info(private$handle, 30, NULL), "get the connection's information", 30, call = field_call("conn", field)))
    },
    require_tcp = function(what) {
      if (private$network_code != 1L) {
        abort_invalid("{.code ${what}()} is only supported on TCP connections.", call = parent.frame())
      }
    },
    payload = function(data) {
      data = as_payload(data, call = parent.frame())
      if (private$network_code == 2L && length(data) > udp_max_payload) {
        abort_invalid("UDP datagrams are limited to {udp_max_payload} bytes, not {length(data)}.", call = parent.frame())
      }
      data
    }
  )
)

check_count = function(n, call = parent.frame()) {
  if (!is.numeric(n) || length(n) != 1 || is.na(n) || n < 0 || n != trunc(n) || n > .Machine$integer.max) {
    abort_invalid("{.arg n} must be a single non-negative whole number of bytes.", call = call)
  }
  as.double(n)
}

check_as = function(as, call = parent.frame()) {
  match_choice(as, c("raw", "text"), "as", call = call)
}

check_max_bytes = function(max_bytes, call = parent.frame()) {
  if (!is.numeric(max_bytes) || length(max_bytes) != 1 || is.na(max_bytes) || max_bytes < 0 || (is.finite(max_bytes) && max_bytes != trunc(max_bytes))) {
    abort_invalid("{.arg max_bytes} must be a single non-negative whole number of bytes or {.code Inf}.", call = call)
  }
  as.double(max_bytes)
}

# Never reads past max_bytes + 1, so a stream that is too long is detected
# while consuming as little of the rest as possible.
read_all_chunk = function(max_bytes, total) {
  min(65536, max_bytes - total + 1)
}

too_long_headline = function(max_bytes) {
  paste0("The stream is longer than `max_bytes` (", format(max_bytes, scientific = FALSE, big.mark = ","), if (max_bytes == 1) " byte" else " bytes", ").")
}

too_long_bullets = c(i = "The bytes read were discarded; the connection stays open.")

byte_total = function(total) {
  if (total <= .Machine$integer.max) as.integer(total) else total
}

convert_read = function(x, as, call = parent.frame()) {
  if (is.null(x) || as == "raw") {
    return(x)
  }
  if (any(x == as.raw(0))) {
    abort_invalid("The data read contains NUL bytes, which a string cannot hold; read it with {.code as = \"raw\"}.", call = call)
  }
  out = rawToChar(x)
  Encoding(out) = "UTF-8"
  out
}
