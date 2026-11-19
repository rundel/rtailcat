# Scalar predicates for argument checks. is_whole() accepts Inf.
is_string = function(x) {
  is.character(x) && length(x) == 1 && !is.na(x)
}

is_nonempty_string = function(x) {
  is_string(x) && nzchar(x)
}

is_number = function(x) {
  is.numeric(x) && length(x) == 1 && !is.na(x)
}

is_whole = function(x) {
  is_number(x) && x == trunc(x)
}

check_timeout = function(timeout, arg = "timeout", call = rlang::caller_env()) {
  if (!is_number(timeout) || timeout < 0) {
    abort_invalid(
      "{.arg {arg}} must be a single non-negative number of seconds or {.code Inf}.",
      call = call
    )
  }
  as.double(timeout)
}

check_port = function(port, allow_zero = TRUE, call = rlang::caller_env()) {
  lower = if (allow_zero) 0 else 1
  if (!is_whole(port) || port < lower || port > 65535) {
    abort_invalid("{.arg port} must be a single integer between {lower} and 65535.", call = call)
  }
  as.integer(port)
}

check_string = function(x, arg, null_ok = FALSE, trim = FALSE, call = rlang::caller_env()) {
  if (null_ok && is.null(x)) {
    return(NULL)
  }
  x = reveal(x)
  if (trim && is_string(x)) {
    x = trimws(x)
  }
  if (!is_nonempty_string(x)) {
    abort_invalid("{.arg {arg}} must be a single non-empty string.", call = call)
  }
  enc2utf8(x)
}

# A NULL argument falls back to the rtailcat.derp_map_url option.
check_derp_map_url = function(derp_map_url, call = rlang::caller_env()) {
  if (!is.null(derp_map_url)) {
    return(check_string(derp_map_url, "derp_map_url", call = call))
  }
  value = getOption("rtailcat.derp_map_url")
  if (is.null(value)) {
    return(NULL)
  }
  if (!is_nonempty_string(value)) {
    abort_invalid(
      "The {.code rtailcat.derp_map_url} option must be a single non-empty string or {.code NULL}.",
      call = call
    )
  }
  enc2utf8(value)
}

check_address = function(address, call = rlang::caller_env()) {
  check_string(address, "address", trim = TRUE, call = call)
}

check_function = function(x, arg, null_ok = FALSE, call = rlang::caller_env()) {
  if ((null_ok && is.null(x)) || is.function(x)) {
    return(x)
  }
  abort_invalid("{.arg {arg}} must be a function.", call = call)
}

# The rule for every choice argument (`network`, `as`): the untouched default
# means its first value, otherwise exactly one of the values (no partial
# matching, no case folding).
match_choice = function(x, choices, arg, call = rlang::caller_env()) {
  if (identical(x, choices)) {
    return(choices[[1]])
  }
  if (!is_string(x) || !(x %in% choices)) {
    abort_invalid("{.arg {arg}} must be one of {.val {choices}}.", call = call)
  }
  x
}

check_path = function(path, call = rlang::caller_env()) {
  if (!is_nonempty_string(path)) {
    abort_invalid("{.arg path} must be a single non-empty string.", call = call)
  }
  path.expand(path)
}

check_flag = function(x, arg, call = rlang::caller_env()) {
  if (!isTRUE(x) && !isFALSE(x)) {
    abort_invalid("{.arg {arg}} must be {.code TRUE} or {.code FALSE}.", call = call)
  }
  x
}

check_key = function(key, call = rlang::caller_env()) {
  if (is.null(key)) {
    return(list())
  }
  if (inherits(key, "tailcat_keys")) {
    parts = if (is.list(key)) {
      unclass(key)[c("private_key", "public_key", "preshared_key")]
    } else {
      list()
    }
    valid = length(parts) == 3 && all(vapply(parts, \(x) is_nonempty_string(reveal(x)), logical(1)))
    if (!valid) {
      abort_invalid(
        c(
          "{.arg key} is a {.cls tailcat_keys} object without a complete set of keys.",
          i = "Create one with {.fn tailcat_keygen}."
        ),
        call = call
      )
    }
    return(list(
      private_key = enc2utf8(reveal(parts$private_key)),
      preshared_key = enc2utf8(reveal(parts$preshared_key))
    ))
  }
  list(private_key = check_string(key, "key", call = call))
}

check_region = function(region, what = "{.arg region}", call = rlang::caller_env()) {
  if (is_string(region)) {
    region = tryCatch(
      jsonlite::fromJSON(region, simplifyVector = FALSE),
      error = \(e) abort_invalid(paste(what, "is not valid JSON."), call = call)
    )
  }
  if (!is.list(region)) {
    abort_invalid(paste(what, "must be a list or a JSON string."), call = call)
  }
  upstream_fields(region)
}

check_count = function(n, call = rlang::caller_env()) {
  if (!is_whole(n) || n < 0 || n > .Machine$integer.max) {
    abort_invalid("{.arg n} must be a single non-negative whole number of bytes.", call = call)
  }
  as.double(n)
}

check_as = function(as, call = rlang::caller_env()) {
  match_choice(as, c("raw", "text"), "as", call = call)
}

check_max_bytes = function(max_bytes, call = rlang::caller_env()) {
  if (!is_whole(max_bytes) || max_bytes < 0) {
    abort_invalid(
      "{.arg max_bytes} must be a single non-negative whole number of bytes or {.code Inf}.",
      call = call
    )
  }
  as.double(max_bytes)
}
