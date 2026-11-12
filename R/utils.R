`%||%` = function(x, y) if (is.null(x)) y else x

rtc_callback = function(body, on_error = NULL) {
  force(body)
  force(on_error)
  function(result) {
    tryCatch(
      body(result),
      error = function(e) {
        if (!is.null(on_error)) {
          tryCatch(on_error(e), error = function(e2) NULL)
        }
      }
    )
    invisible(NULL)
  }
}

rtc_promise = function(start, transform = identity, ..., call = rlang::caller_env()) {
  call = error_call(call)
  context = list(...)
  handle = NULL
  p = promises::promise(function(resolve, reject) {
    handle <<- start(rtc_callback(
      function(result) {
        if (inherits(result, "rtc_error")) {
          reject(rlang::exec(rtc_condition, result, !!!context, call = call))
        } else {
          resolve(transform(result))
        }
      },
      on_error = reject
    ))
  })
  with_canceler(p, function() rtc_cancel(handle))
}

# The canceler is attached to the promise object itself, so promises derived
# with then() do not carry it.
with_canceler = function(promise, canceler) {
  attr(promise, "rtailcat_cancel") = canceler
  promise
}

canceled_error = function(bytes = 0L) {
  structure(list(status = 4L, message = "", bytes = bytes), class = "rtc_error")
}

check_timeout = function(timeout, arg = "timeout", call = parent.frame()) {
  if (!is.numeric(timeout) || length(timeout) != 1 || is.na(timeout) || timeout < 0) {
    abort_invalid("{.arg {arg}} must be a single non-negative number of seconds or {.code Inf}.", call = call)
  }
  as.double(timeout)
}

check_port = function(port, allow_zero = TRUE, call = parent.frame()) {
  lower = if (allow_zero) 0 else 1
  if (!is.numeric(port) || length(port) != 1 || is.na(port) || port != trunc(port) || port < lower || port > 65535) {
    abort_invalid("{.arg port} must be a single integer between {lower} and 65535.", call = call)
  }
  as.integer(port)
}

check_string = function(x, arg, null_ok = FALSE, trim = FALSE, call = parent.frame()) {
  if (null_ok && is.null(x)) {
    return(NULL)
  }
  x = reveal(x)
  if (trim && is.character(x) && length(x) == 1 && !is.na(x)) {
    x = trimws(x)
  }
  if (!is.character(x) || length(x) != 1 || is.na(x) || !nzchar(x)) {
    abort_invalid("{.arg {arg}} must be a single non-empty string.", call = call)
  }
  enc2utf8(x)
}

check_address = function(address, call = parent.frame()) {
  check_string(address, "address", trim = TRUE, call = call)
}

check_function = function(x, arg, null_ok = FALSE, call = parent.frame()) {
  if ((null_ok && is.null(x)) || is.function(x)) {
    return(x)
  }
  abort_invalid("{.arg {arg}} must be a function.", call = call)
}

# The rule for every choice argument (`network`, `as`): the untouched default
# means its first value, otherwise exactly one of the values (no partial
# matching, no case folding).
match_choice = function(x, choices, arg, call = parent.frame()) {
  if (identical(x, choices)) {
    return(choices[[1]])
  }
  if (!is.character(x) || length(x) != 1 || is.na(x) || !(x %in% choices)) {
    abort_invalid("{.arg {arg}} must be one of {.val {choices}}.", call = call)
  }
  x
}

network_code = function(network, call = parent.frame()) {
  match(match_choice(network, c("tcp", "udp"), "network", call = call), c("tcp", "udp"))
}

network_name = function(code) {
  c("tcp", "udp")[[code]]
}

from_json = function(x) {
  jsonlite::fromJSON(x, simplifyVector = TRUE, simplifyDataFrame = FALSE, simplifyMatrix = FALSE)
}

to_json = function(x) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA, null = "null", json_verbatim = TRUE))
}

endpoint_port = function(endpoint) {
  if (is.null(endpoint) || !is.character(endpoint) || length(endpoint) != 1) {
    return(NA_integer_)
  }
  suppressWarnings(as.integer(sub("^.*:", "", endpoint)))
}

parse_info = function(json) {
  info = tailcat_fields(from_json(json))
  if (!is.null(info$network)) {
    info$network = network_name(info$network)
  }
  if (!is.null(info$address)) {
    info$address = new_secret(info$address)
  }
  info
}

as_payload = function(data, call = parent.frame()) {
  if (is.raw(data)) {
    return(data)
  }
  if (is.character(data)) {
    if (anyNA(data)) {
      abort_invalid("{.arg data} must not contain missing values.", call = call)
    }
    return(charToRaw(enc2utf8(paste(data, collapse = ""))))
  }
  abort_invalid("{.arg data} must be a raw vector or a character vector.", call = call)
}

deadline_from = function(timeout) {
  if (is.infinite(timeout)) Inf else as.double(Sys.time()) + timeout
}

remaining_until = function(deadline) {
  if (is.infinite(deadline)) Inf else max(0, deadline - as.double(Sys.time()))
}

state_label = function(closed, started = TRUE, handle = NULL) {
  if (closed && !is.null(handle) && rtc_is_restored(handle)) {
    return("closed (restored from a saved session)")
  }
  if (closed) "closed" else if (started) "open" else "not started"
}

safely = function(expr, default = NULL) {
  tryCatch(expr, error = function(e) default)
}

udp_max_payload = 1232L

# Each operation in flight holds an OS thread, and each of those threads also
# holds a Go runtime thread while it is inside tailcat. 1024 stays well below
# the macOS per-process thread limit (kern.num_taskthreads, 6144 on arm64),
# common Linux per-user limits (ulimit -u of 4096 and up), and the Go
# runtime's own limit of 10000 threads, which ends the process when exceeded.
max_operations_default = 1024

# Called by the native layer at every submission. NA tells it the option is
# invalid.
max_operations_option = function() {
  x = getOption("rtailcat.max_operations", max_operations_default)
  valid = is.numeric(x) && length(x) == 1 && !is.na(x) && x >= 1 && (is.infinite(x) || x == trunc(x))
  if (valid) as.double(x) else NA_real_
}

is_tailcat_object = function(x, classes) {
  R6::is.R6(x) && inherits(x, classes)
}
