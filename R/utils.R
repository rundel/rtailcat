`%||%` = function(x, y) {
  if (is.null(x)) y else x
}

rtc_callback = function(body, on_error = NULL) {
  force(body)
  force(on_error)
  function(result) {
    tryCatch(
      body(result),
      error = function(e) {
        if (!is.null(on_error)) {
          tryCatch(on_error(e), error = \(e2) NULL)
        }
      }
    )
    invisible()
  }
}

rtc_promise = function(start, transform = identity, ..., call = rlang::caller_env()) {
  call = error_call(call)
  context = list(...)
  handle = NULL
  promise = promises::promise(function(resolve, reject) {
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
  with_canceler(promise, \() rtc_cancel(handle))
}

# The canceler is attached to the promise object itself, so promises derived
# with then() do not carry it.
with_canceler = function(promise, canceler) {
  attr(promise, "rtailcat_cancel") = canceler
  promise
}

canceled_error = function(bytes = 0L) {
  structure(list(status = status_canceled, message = "", bytes = bytes), class = "rtc_error")
}

network_tcp = 1L
network_udp = 2L

network_code = function(network, call = rlang::caller_env()) {
  match(match_choice(network, c("tcp", "udp"), "network", call = call), c("tcp", "udp"))
}

network_name = function(code) {
  c("tcp", "udp")[[code]]
}

from_json = function(x) {
  jsonlite::fromJSON(x, simplifyVector = TRUE, simplifyDataFrame = FALSE, simplifyMatrix = FALSE)
}

to_json = function(x) {
  as.character(jsonlite::toJSON(
    x,
    auto_unbox = TRUE,
    digits = NA,
    null = "null",
    json_verbatim = TRUE
  ))
}

endpoint_port = function(endpoint) {
  if (!is_string(endpoint)) {
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

as_payload = function(data, call = rlang::caller_env()) {
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
  if (closed) {
    "closed"
  } else if (started) {
    "open"
  } else {
    "not started"
  }
}

safely = function(expr, default = NULL) {
  tryCatch(expr, error = \(e) default)
}

udp_max_payload = 1232L

# Seconds an active binding, and a format() method, wait for tailcat's answer.
field_timeout = 30
format_timeout = 5

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
  if (is_whole(x) && x >= 1) as.double(x) else NA_real_
}

is_tailcat_object = function(x, classes) {
  R6::is.R6(x) && inherits(x, classes)
}

# A latency that is a whole number of seconds (0 on a coarse clock) parses as an integer.
parse_disco_ping = function(text) {
  x = parse_json(text)
  x$latency = as.double(x$latency)
  x
}

parse_json = function(json) {
  tailcat_fields(from_json(json))
}
