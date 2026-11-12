#' Tailcat listener
#'
#' @description
#' A listener accepts TCP connections or UDP flows on one port of a [TailcatServer]. Listeners are created by `TailcatServer$listen()`, not directly.
#'
#' Accepted connections belong to the server rather than the listener: closing the listener stops new connections but leaves accepted ones open, while closing the server closes everything.
#'
#' Once the listener or its server is closed, every method other than `$close()`, `$stop_serving()`, `$format()`, and `$print()`, and every field other than `$is_closed` and `$server`, raises a `tailcat_closed` error. Timeouts (including `timeout = 0`, a poll) and errors are described in [TailcatServer].
#'
#' @section Serving connections:
#' `$serve(handler)` starts an accept loop driven by the later event loop and returns immediately. Each new connection is passed to `handler(conn)` on the main R thread. The loop only makes progress while the event loop runs: when R is idle at the console, inside Shiny or httpuv, or while a script calls [later::run_now()] in a loop. Blocking calls inside the handler (such as `conn$read()`) hold up the loop until they return, so long-running handlers should use the `_async()` methods and return the resulting promise. A handler may return a promise (or anything [promises::is.promising()] accepts): if it rejects, the rejection is treated like an error signaled by the handler, so `on_error` is called and the connection is closed. The loop does not wait for the promise before accepting the next connection. The loop ends quietly when the listener or the server is closed, or when `$stop_serving()` is called; `$stop_serving()` leaves the listener open, so it can accept connections again or serve with a new handler.
#'
#' @examples
#' \dontrun{
#' srv = TailcatServer$new()
#' lst = srv$listen(7)
#' lst$serve(function(conn) {
#'   promises::then(conn$read_all_async(timeout = 30), function(data) {
#'     conn$write(data)
#'     conn$close()
#'   })
#' })
#' srv$address
#' }
#' @export
TailcatListener = R6::R6Class(
  "TailcatListener",
  cloneable = FALSE,
  public = list(
    #' @description Internal constructor; use `TailcatServer$listen()`.
    #' @param handle Native listener handle.
    #' @param server The owning [TailcatServer].
    #' @param network Integer network code.
    initialize = function(handle, server, network) {
      if (!inherits(handle, "rtc_listener") || !is_tailcat_object(server, "TailcatServer")) {
        abort_invalid("Listeners are created by {.code TailcatServer$listen()}.")
      }
      private$handle = handle
      private$parent = server
      private$network_code = as.integer(network)
      invisible(self)
    },

    #' @description Wait for the next connection (TCP) or new flow (UDP). A timeout ends only this call; the listener stays usable.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls (returns a connection that is already waiting).
    #' @return A [TailcatConnection].
    accept = function(timeout = Inf) {
      timeout = check_timeout(timeout)
      h = private$check(rtc_listener_accept(private$handle, timeout, NULL), "accept a connection", timeout)
      private$wrap(h)
    },

    #' @description Asynchronous version of `$accept()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with a [TailcatConnection].
    accept_async = function(timeout = Inf) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_listener_accept(private$handle, timeout, cb), private$wrap, "accept a connection", timeout)
    },

    #' @description Start an asynchronous accept loop that calls `handler(conn)` for every connection. See the section on serving connections.
    #' @param handler A function of one argument, the [TailcatConnection]. It may return a promise.
    #' @param on_error A function `function(cond, conn)` called when `handler` signals an error or the promise it returned rejects (or when accepting fails, with `conn = NULL`), or `NULL` to turn such errors into warnings (signaled from the later event loop). After a handler error the connection is closed. An error signaled by `on_error` itself is turned into a warning.
    #' @return The listener, invisibly. Calling it on a listener that is already serving raises a `tailcat_failure` error (call `$stop_serving()` first), and on a closed listener a `tailcat_closed` error.
    serve = function(handler, on_error = NULL) {
      check_function(handler, "handler")
      check_function(on_error, "on_error", null_ok = TRUE)
      if (self$is_closed) {
        abort_closed("listener", private$handle)
      }
      if (private$serving) {
        tailcat_abort(5L, headline = "This listener is already serving.", bullets = c(i = "Call `$stop_serving()` first to serve with a new handler."))
      }
      private$serving = TRUE
      private$serve_gen = private$serve_gen + 1L
      private$serve_next(handler, on_error, private$serve_gen)
      invisible(self)
    },

    #' @description Stop the accept loop started by `$serve()` without closing the listener. The pending accept is canceled; connections already accepted are not affected, and a connection whose accept completed at the same moment is still passed to the handler. Calling it when the listener is not serving does nothing.
    #' @return The listener, invisibly.
    stop_serving = function() {
      if (private$serving) {
        private$serving = FALSE
        private$serve_gen = private$serve_gen + 1L
        if (!is.null(private$serve_cancel)) {
          rtc_cancel(private$serve_cancel)
          private$serve_cancel = NULL
        }
      }
      invisible(self)
    },

    #' @description Information about the listener.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A list with `local_address` and `network`.
    info = function(timeout = 30) {
      timeout = check_timeout(timeout)
      parse_info(private$check(rtc_info(private$handle, timeout, NULL), "get the listener's information", timeout))
    },

    #' @description Asynchronous version of `$info()`.
    #' @param timeout Seconds to wait; `Inf` waits indefinitely and `0` polls.
    #' @return A promise resolving with the info list.
    info_async = function(timeout = 30) {
      timeout = check_timeout(timeout)
      private$promise(function(cb) rtc_info(private$handle, timeout, cb), parse_info, "get the listener's information", timeout)
    },

    #' @description Stop accepting connections. Accepted connections stay open. Closing twice is harmless.
    #' @return The listener, invisibly.
    close = function() {
      rtc_close(private$handle)
      invisible(self)
    },

    #' @description Format a summary, the lines that `$print()` shows.
    #' @param ... Ignored.
    #' @return A character vector.
    format = function(...) {
      closed = self$is_closed
      lines = c(
        "<TailcatListener>",
        paste0("  state:   ", state_label(closed, handle = private$handle), if (private$serving && !closed) " (serving)" else ""),
        paste0("  network: ", network_name(private$network_code))
      )
      if (!closed) {
        port = safely(endpoint_port(parse_info(rtc_value(rtc_info(private$handle, 5, NULL)))$local_address), NA_integer_)
        lines = c(lines, paste0("  port:    ", if (is.na(port)) "<unknown>" else port))
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
    #' @field port The port number being listened on.
    port = function(value) {
      endpoint_port(private$field_info("port", value)$local_address)
    },
    #' @field local_address The local endpoint as `"host:port"` on the server's tailcat network (not the secret tailcat address).
    local_address = function(value) {
      private$field_info("local_address", value)$local_address
    },
    #' @field network `"tcp"` or `"udp"`.
    network = function(value) {
      private$read_only("network", value)
      if (self$is_closed) {
        abort_closed("listener", private$handle, call = field_call("lst", "network"))
      }
      network_name(private$network_code)
    },
    #' @field server The owning [TailcatServer].
    server = function(value) {
      private$read_only("server", value)
      private$parent
    },
    #' @field is_closed `TRUE` once the listener or its server has been closed.
    is_closed = function(value) {
      private$read_only("is_closed", value)
      rtc_is_closed(private$handle) || private$parent$is_closed
    }
  ),
  private = list(
    handle = NULL,
    parent = NULL,
    network_code = NULL,
    serving = FALSE,
    serve_gen = 0L,
    serve_cancel = NULL,
    check = function(x, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_value(x, op = op, object = "listener", timeout = timeout, handle = private$handle, ..., call = call)
    },
    promise = function(start, transform, op, timeout = NULL, ..., call = rlang::caller_env()) {
      rtc_promise(start, transform, op = op, object = "listener", timeout = timeout, handle = private$handle, ..., call = call)
    },
    read_only = function(field, value) {
      if (!missing(value)) {
        abort_invalid("{.field {field}} is read-only.", call = field_call("lst", field))
      }
    },
    field_info = function(field, value) {
      private$read_only(field, value)
      parse_info(private$check(rtc_info(private$handle, 30, NULL), "get the listener's information", 30, call = field_call("lst", field)))
    },
    wrap = function(h) {
      TailcatConnection$new(h, private$parent, private$network_code)
    },
    serve_next = function(handler, on_error, gen) {
      if (gen != private$serve_gen) {
        return(invisible())
      }
      if (self$is_closed) {
        private$serving = FALSE
        private$serve_cancel = NULL
        return(invisible())
      }
      private$serve_cancel = rtc_listener_accept(private$handle, Inf, rtc_callback(
        function(result) private$serve_result(result, handler, on_error, gen),
        on_error = function(e) {
          if (gen == private$serve_gen) {
            private$serving = FALSE
            private$serve_cancel = NULL
          }
          deferred_warning(paste0("rtailcat: serve() loop stopped: ", conditionMessage(e)))
        }
      ))
      invisible()
    },
    serve_result = function(result, handler, on_error, gen) {
      current = gen == private$serve_gen
      if (inherits(result, "rtc_error")) {
        if (!current) {
          return(invisible())
        }
        if (result$status == 2L || self$is_closed) {
          private$serving = FALSE
          private$serve_cancel = NULL
          return(invisible())
        }
        report_error(rtc_condition(result, op = "accept a connection", object = "listener", handle = private$handle), NULL, on_error, "accepting a connection")
        later::later(function() {
          tryCatch(private$serve_next(handler, on_error, gen), error = function(e) {
            if (gen == private$serve_gen) {
              private$serving = FALSE
            }
            deferred_warning(paste0("rtailcat: serve() loop stopped: ", conditionMessage(e)))
          })
        }, delay = 1)
        return(invisible())
      }
      conn = private$wrap(result)
      if (current) {
        private$serve_next(handler, on_error, gen)
      }
      handler_failed = function(e) {
        report_error(e, conn, on_error, "the connection handler")
        tryCatch(conn$close(), error = function(e2) NULL)
        invisible()
      }
      tryCatch(
        {
          value = handler(conn)
          if (promises::is.promising(value)) {
            promises::catch(promises::as.promise(value), handler_failed)
          }
        },
        error = handler_failed
      )
      invisible()
    }
  )
)

report_error = function(cond, conn, on_error, where) {
  if (is.null(on_error)) {
    deferred_warning(paste0("rtailcat: error in ", where, ": ", conditionMessage(cond)))
    return(invisible())
  }
  tryCatch(
    on_error(cond, conn),
    error = function(e) {
      deferred_warning(paste0("rtailcat: error in the on_error callback: ", conditionMessage(e)))
    }
  )
  invisible()
}

deferred_warning = function(message) {
  later::later(function() warning(message, call. = FALSE))
  invisible()
}
