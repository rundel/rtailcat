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
  if (!run_loop(function() state$done, timeout)) {
    tailcat_abort(3L, op = "wait for the promise", timeout = timeout)
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
  condition = if (is.null(until)) function() FALSE else function() isTRUE(until())
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
