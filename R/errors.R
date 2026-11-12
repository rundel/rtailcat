rtc_error_kinds = c("invalid_argument", "closed", "timeout", "canceled", "failure")

rtc_error_class = function(status) {
  kind = if (is.numeric(status) && length(status) == 1 && !is.na(status) && status %in% seq_along(rtc_error_kinds)) {
    rtc_error_kinds[[status]]
  } else {
    "failure"
  }
  c(paste0("tailcat_", kind), "tailcat_error")
}

# Every condition the package signals is built here, from a status and the
# context of the call, for synchronous errors and promise rejections alike.
#
# - detail: tailcat's own text; it becomes one unwrapped "i" line.
# - op: what the call was doing, as a verb phrase ("read", "dial port 80").
# - object: "server", "client", "listener", or "connection".
# - arg: the argument an invalid-argument status is about, if known.
# - timeout: the timeout in seconds the call was given.
# - handle: lets a closed status say that the handle was restored from a
#   saved session.
# - headline, bullets: replace the default headline or add lines.
tailcat_condition = function(status, detail = NULL, bytes = 0L, op = NULL, object = NULL, arg = NULL,
                             timeout = NULL, handle = NULL, headline = NULL, bullets = NULL, hint = NULL,
                             invalid_headline = NULL, call = NULL) {
  class = rtc_error_class(status)
  kind = sub("^tailcat_", "", class[[1]])
  if (kind == "invalid_argument" && is.null(headline)) {
    headline = invalid_headline
  }
  if (is.null(headline)) {
    restored = kind == "closed" && !is.null(handle) && isTRUE(safely(rtc_is_restored(handle), FALSE))
    headline = default_headline(kind, op, object, arg, timeout, restored)
    if (restored) {
      bullets = c(bullets, i = cli::format_inline(
        "Handles do not survive serialization ({.fn saveRDS}, {.fn save}, or a saved workspace); create a new {object %||% 'object'}."
      ))
    }
  }
  if (kind == "timeout" && !identical(timeout, 0)) {
    bullets = c(bullets, hint)
  }
  detail = upstream_detail(detail)
  lines = c(headline, bullet_lines(c(if (!is.null(detail)) c(i = detail), bullets)))
  rlang::error_cnd(
    class = class,
    message = paste(lines, collapse = "\n"),
    call = error_call(call),
    status = if (is.numeric(status) && length(status) == 1) as.integer(status) else 5L,
    bytes = bytes %||% 0L
  )
}

tailcat_abort = function(status, ..., call = rlang::caller_env()) {
  cnd = tailcat_condition(status, ..., call = call)
  cnd$trace = rlang::trace_back(bottom = entry_frame())
  rlang::cnd_signal(cnd)
}

# The outermost frame of a package function (the method, field, or function
# the user called), so that backtraces end where the user's code does.
entry_frame = function() {
  ns = topenv(environment(entry_frame))
  for (i in seq_len(sys.nframe())) {
    env = environment(sys.function(i))
    if (!is.null(env) && identical(topenv(env), ns)) {
      return(sys.frame(i))
    }
  }
  rlang::caller_env()
}

# For a result from the native layer, which reports failures as values.
rtc_condition = function(err, ..., bytes = NULL, call = NULL) {
  tailcat_condition(err$status, detail = err$message, bytes = bytes %||% err$bytes, ..., call = call)
}

rtc_abort = function(err, ..., bytes = NULL, call = rlang::caller_env()) {
  tailcat_abort(err$status, detail = err$message, bytes = bytes %||% err$bytes, ..., call = call)
}

rtc_value = function(x, ..., call = rlang::caller_env()) {
  if (inherits(x, "rtc_error")) {
    rtc_abort(x, ..., call = call)
  }
  x
}

abort_invalid = function(message, call = rlang::caller_env(), .envir = parent.frame()) {
  text = vapply(message, cli::format_inline, "", .envir = .envir, USE.NAMES = FALSE)
  names(text) = names(message)
  tailcat_abort(1L, headline = text[[1]], bullets = text[-1], call = call)
}

abort_closed = function(object, handle = NULL, call = rlang::caller_env()) {
  tailcat_abort(2L, object = object, handle = handle, call = call)
}

default_headline = function(kind, op, object, arg, timeout, restored) {
  op = op %||% "complete the operation"
  object = object %||% "object"
  switch(kind,
    invalid_argument = if (is.null(arg)) {
      cli::format_inline("Could not {op}: an argument is invalid.")
    } else {
      cli::format_inline("{.arg {arg}} is invalid.")
    },
    closed = if (restored) {
      paste0("This ", object, " was restored from a saved session and can no longer be used.")
    } else {
      paste0("The ", object, " is closed.")
    },
    timeout = if (is.null(timeout) || is.infinite(timeout)) {
      paste0("Timed out trying to ", op, ".")
    } else if (timeout == 0) {
      cli::format_inline("Could not {op} without waiting ({.code timeout = 0}).")
    } else {
      paste0("Timed out after ", format_seconds(timeout), " trying to ", op, ".")
    },
    canceled = paste0("Canceled while trying to ", op, "."),
    paste0("Could not ", op, ".")
  )
}

format_seconds = function(x) {
  text = trimws(formatC(x, format = "fg", digits = 6))
  paste(text, if (x == 1) "second" else "seconds")
}

# tailcat's text on one line, without the "invalid argument: " prefix that
# repeats the condition class. Text from the native layer itself starts with
# "rtailcat: " and keeps that prefix instead.
upstream_detail = function(message) {
  if (!is.character(message) || length(message) != 1 || is.na(message)) {
    return(NULL)
  }
  text = trimws(gsub("[[:space:]]+", " ", message))
  text = sub("^invalid argument: ", "", text)
  if (!nzchar(text)) {
    return(NULL)
  }
  if (startsWith(text, "rtailcat: ")) text else paste0("tailcat: ", text)
}

bullet_lines = function(bullets) {
  if (length(bullets) == 0) {
    return(character())
  }
  kinds = names(bullets) %||% rep("", length(bullets))
  symbols = c(i = cli::symbol$info, x = cli::symbol$cross, v = cli::symbol$tick, `!` = "!", `*` = cli::symbol$bullet)
  prefix = ifelse(kinds %in% names(symbols), symbols[kinds], " ")
  paste(prefix, unname(bullets))
}

error_call = function(call) {
  if (is.environment(call)) rlang::frame_call(call) else call
}

# Which constructor argument an upstream configuration error is about. The
# fallbacks keep the error usable if the wording changes.
config_arg = function(detail, args) {
  text = tolower(detail %||% "")
  patterns = c(
    preshared_key = "pre-shared key",
    key = "private key",
    allowed_clients = "allowed client",
    udp_idle_timeout = "udp idle",
    address = "address",
    region = "unknown field|invalid configuration|trailing configuration"
  )
  for (arg in names(patterns)) {
    if (arg %in% args && grepl(patterns[[arg]], text)) {
      return(arg)
    }
  }
  NULL
}
