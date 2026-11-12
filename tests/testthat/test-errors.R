offline_address = function() {
  tc_address(list(p = as.raw(c(rep(0, 31), 1)), k = as.raw(1:32), q = as.raw(1:32), i = 10))
}

caught = function(expr) {
  tryCatch(expr, error = identity)
}

# The headline is the first line; at most the detail and hint lines follow.
expect_message_shape = function(cond, headline, lines = NULL) {
  msg = conditionMessage(cond)
  parts = strsplit(msg, "\n", fixed = TRUE)[[1]]
  expect_match(parts[[1]], headline)
  if (!is.null(lines)) {
    expect_length(parts, lines)
  }
  invisible(parts)
}

test_that("each status has its own headline naming the operation or object", {
  err = function(status, message = "") structure(list(status = status, message = message, bytes = 0L), class = "rtc_error")
  cond = function(status, ...) rtailcat:::rtc_condition(err(status, "upstream text"), ...)

  expect_message_shape(cond(1L, op = "read", arg = "n"), "^`n` is invalid\\.$")
  expect_message_shape(cond(1L, op = "dial port 80"), "^Could not dial port 80: an argument is invalid\\.$")
  expect_message_shape(cond(2L, op = "read", object = "connection"), "^The connection is closed\\.$")
  expect_message_shape(cond(2L, object = "listener"), "^The listener is closed\\.$")
  expect_message_shape(cond(3L, op = "read", timeout = 30), "^Timed out after 30 seconds trying to read\\.$")
  expect_message_shape(cond(3L, op = "read", timeout = 1), "^Timed out after 1 second trying to read\\.$")
  expect_message_shape(cond(3L, op = "read", timeout = 0.25), "^Timed out after 0\\.25 seconds trying to read\\.$")
  expect_message_shape(cond(3L, op = "accept a connection", timeout = 0), "^Could not accept a connection without waiting \\(`timeout = 0`\\)\\.$")
  expect_message_shape(cond(4L, op = "read"), "^Canceled while trying to read\\.$")
  expect_message_shape(cond(5L, op = "dial port 80"), "^Could not dial port 80\\.$")
  for (status in 1:5) {
    parts = expect_message_shape(cond(status, op = "read"), ".", lines = 2)
    expect_match(parts[[2]], "tailcat: upstream text$")
  }
})

test_that("tailcat's text is one unwrapped detail line without the redundant prefix", {
  long = paste("invalid argument:", paste(rep("a long upstream message", 20), collapse = " "), "\nwith a newline")
  withr::local_options(width = 20, cli.width = 20)
  cond = rtailcat:::rtc_condition(structure(list(status = 5L, message = long, bytes = 0L), class = "rtc_error"), op = "read")
  parts = strsplit(conditionMessage(cond), "\n", fixed = TRUE)[[1]]
  expect_length(parts, 2)
  expect_false(grepl("invalid argument:", parts[[2]], fixed = TRUE))
  expect_match(parts[[2]], "tailcat: a long upstream message .* with a newline$")

  quiet = rtailcat:::rtc_condition(structure(list(status = 3L, message = "", bytes = 0L), class = "rtc_error"), op = "read", timeout = 2)
  expect_identical(conditionMessage(quiet), "Timed out after 2 seconds trying to read.")
  native = rtailcat:::rtc_condition(structure(list(status = 5L, message = "rtailcat: could not start a worker thread", bytes = 0L), class = "rtc_error"), op = "read")
  expect_match(conditionMessage(native), "\nrtailcat: could not start|rtailcat: could not start")
  expect_false(grepl("tailcat: rtailcat:", conditionMessage(native), fixed = TRUE))
})

test_that("real errors carry a headline, an unwrapped detail, and the user-facing call", {
  withr::local_options(width = 20, cli.width = 20)
  cond = caught(TailcatServer$new(key = "privkey:nope"))
  expect_s3_class(cond, "tailcat_invalid_argument")
  expect_identical(cond$status, 1L)
  parts = expect_message_shape(cond, "`key`", lines = 2)
  expect_match(parts[[2]], "^. tailcat: [^\n]*private key")
  expect_false(grepl("invalid argument:", conditionMessage(cond), fixed = TRUE))
  expect_identical(deparse(cond$call[[1]]), "TailcatServer$new")

  expect_message_shape(caught(TailcatServer$new(preshared_key = "nope")), "`preshared_key`")
  expect_message_shape(caught(TailcatServer$new(allowed_clients = "nope")), "`allowed_clients`")
  expect_message_shape(caught(TailcatClient$new(offline_address(), key = "nope")), "`key`")
  expect_identical(deparse(caught(TailcatClient$new("nope"))$call[[1]]), "TailcatClient$new")
  expect_message_shape(caught(TailcatClient$new("nope")), "`address`")
  expect_message_shape(caught(TailcatServer$new(region_id = -1)), "`region_id`")
  expect_identical(deparse(caught(TailcatServer$new(region_id = -1))$call[[1]]), "TailcatServer$new")

  parsed = caught(tailcat_address_parse("not an address"))
  expect_message_shape(parsed, "`address` is invalid", lines = 2)
  expect_identical(deparse(parsed$call[[1]]), "tailcat_address_parse")

  srv = TailcatServer$new()
  on.exit(srv$close())
  info = caught(srv$info())
  expect_s3_class(info, "tailcat_invalid_argument")
  expect_message_shape(info, "has not started")
  expect_identical(deparse(info$call[[1]]), "srv$info")
  address = caught(srv$address)
  expect_message_shape(address, "has not started")
  expect_identical(deparse(address$call), "srv$address")
  expect_identical(deparse(caught({srv$address = 1})$call), "srv$address")

  map_url = silent_map_url()
  cl = TailcatClient$new(offline_address(), derp_map_url = map_url)
  on.exit(cl$close(), add = TRUE)
  ping = caught(cl$ping(timeout = 0))
  expect_s3_class(ping, "tailcat_timeout")
  expect_identical(ping$status, 3L)
  expect_message_shape(ping, "^Could not ping the server without waiting")
  expect_identical(deparse(ping$call[[1]]), "cl$ping")
  cl$close()
  closed = caught(cl$public_key)
  expect_message_shape(closed, "^The client is closed\\.$", lines = 1)
  expect_identical(deparse(closed$call), "cl$public_key")
})

test_that("async rejections name the call and carry no backtrace", {
  cl = TailcatClient$new(offline_address())
  cl$close()
  cond = caught(wait_for(cl$ping_async(), 10))
  expect_s3_class(cond, "tailcat_closed")
  expect_null(cond$trace)
  expect_identical(deparse(cond$call[[1]]), "cl$ping_async")
  expect_identical(conditionMessage(cond), "The client is closed.")
  expect_false(grepl("Backtrace", paste(utils::capture.output(print(cond)), collapse = "\n"), fixed = TRUE))

  map_url = silent_map_url()
  live = TailcatClient$new(offline_address(), derp_map_url = map_url)
  on.exit(live$close())
  cond = caught(wait_for(live$dial_async(80, timeout = 0), 10))
  expect_s3_class(cond, "tailcat_timeout")
  expect_null(cond$trace)
  expect_match(conditionMessage(cond), "^Could not dial port 80 without waiting")
})

test_that("an unhandled rejection is reported with the headline first", {
  cl = TailcatClient$new(offline_address())
  cl$close()
  cl$ping_async()
  out = utils::capture.output(invisible(run_until(function() FALSE, 1)), type = "message")
  expect_identical(out, "Unhandled promise error: The client is closed.")
})
