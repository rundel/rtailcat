#' Run the event loop from a script
#'
#' Asynchronous results, `TailcatListener$serve()`, and `TailcatConnection$read_loop()` only make progress while the later event loop runs. At the console and inside Shiny that happens on its own; a script run with `Rscript` has to run the loop itself. These functions do that.
#'
#' `tailcat_wait()` runs the event loop until `promise` settles and returns its value, or signals the condition it was rejected with, so a script can use an `_async()` method like a blocking one. `tailcat_run()` runs the event loop until `until()` returns `TRUE` or the timeout runs out; with `until = NULL` it runs until the timeout runs out, which with the default `timeout = Inf` keeps a server script serving until it is interrupted.
#'
#' Both run the current later loop ([later::current_loop()]) and can be interrupted. Nothing else in the script runs meanwhile, except what the event loop runs.
#'
#' @param promise A promise, or anything [promises::is.promising()] accepts.
#' @param until A function of no arguments that returns `TRUE` when the loop should stop, or `NULL`. It is called before each turn of the loop.
#' @param timeout Seconds to wait; `Inf` (the default) waits indefinitely and `0` runs the callbacks that are already due, without waiting. When `tailcat_wait()` times out it raises a `tailcat_timeout` error; the operation behind the promise keeps going (cancel it with [tailcat_cancel()] if it should not).
#' @return `tailcat_wait()` returns the promise's value. `tailcat_run()` returns, invisibly, `TRUE` if `until()` returned `TRUE` and `FALSE` if the timeout ran out.
#' @examples
#' \dontrun{
#' cli = TailcatClient$new(address)
#' conn = tailcat_wait(cli$dial_async(8080), timeout = 30)
#'
#' srv = TailcatServer$new()
#' lst = srv$listen(8080)
#' lst$serve(handler)
#' tailcat_run(until = function() lst$is_closed)
#' }
#' @export
tailcat_wait = function(promise, timeout = Inf) {
  if (!promises::is.promising(promise)) {
    abort_invalid("{.arg promise} must be a promise, not {.obj_type_friendly {promise}}.")
  }
  timeout = check_timeout(timeout)
  state = new.env(parent = emptyenv())
  state$done = FALSE
  promises::then(
    promises::as.promise(promise),
    onFulfilled = function(value) {
      state$value = value
      state$done = TRUE
    },
    onRejected = function(error) {
      state$error = error
      state$done = TRUE
    }
  )
  if (!run_loop(\() state$done, timeout)) {
    tailcat_abort(status_timeout, op = "wait for the promise", timeout = timeout)
  }
  if (!is.null(state$error)) {
    stop(state$error)
  }
  state$value
}

#' @rdname tailcat_wait
#' @export
tailcat_run = function(until = NULL, timeout = Inf) {
  check_function(until, "until", null_ok = TRUE)
  timeout = check_timeout(timeout)
  condition = if (is.null(until)) {
    \() FALSE
  } else {
    \() isTRUE(until())
  }
  invisible(run_loop(condition, timeout))
}

run_loop = function(condition, timeout) {
  deadline = deadline_from(timeout)
  repeat {
    if (condition()) {
      return(TRUE)
    }
    left = remaining_until(deadline)
    later::run_now(min(left, 0.1))
    if (left <= 0) {
      return(condition())
    }
  }
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
    abort_invalid(
      "{.arg promise} must be a promise returned by an rtailcat {.code _async()} method or function, not {.obj_type_friendly {promise}}."
    )
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
