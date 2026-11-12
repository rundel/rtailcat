test_that("a huge n does not make the read allocate it, and one read returns at most 64 KiB", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  pair$client$write(as.raw(1:10))
  started = Sys.time()
  expect_identical(pair$server$read(n = .Machine$integer.max, timeout = 20), as.raw(1:10))
  expect_lt(as.double(Sys.time() - started, units = "secs"), 2)

  payload = as.raw(sample(0:255, 200000, replace = TRUE))
  pair$client$write(payload)
  pair$client$close_write()
  expect_true(run_until(function() pair$server$readable(), 20))
  run_until(function() FALSE, 0.5)
  first = pair$server$read(n = 1e6, timeout = 20)
  expect_lte(length(first), 65536L)
  rest = pair$server$read_all(timeout = 20)
  expect_identical(c(first, rest), payload)
})

test_that("a pending read_async() survives garbage collection of its connection objects", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  state = new.env()
  promises::then(pair$server$read_async(timeout = 30, as = "text"), function(v) state$value = v, function(e) state$error = e)
  writer = pair$client
  rm(pair)
  invisible(gc())
  run_until(function() FALSE, 0.3)
  expect_null(state$value)
  expect_null(state$error)
  writer$write("late data")
  expect_true(run_until(function() !is.null(state$value) || !is.null(state$error), 20))
  expect_identical(state$value, "late data")
})

test_that("canceling or closing in the middle of a large write reports the bytes sent", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  size = 32 * 1024^2
  data = as.raw(sample(0:255, size, replace = TRUE))

  pair = connect_pair(lst, cl, lst$port)
  pending = pair$client$write_async(data, timeout = 60)
  run_until(function() FALSE, 0.5)
  tailcat_cancel(pending)
  cond = tryCatch(wait_for(pending, 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_canceled")
  expect_gt(as.double(cond$bytes), 0)
  expect_lt(as.double(cond$bytes), size)
  expect_false(pair$client$is_closed)

  pair = connect_pair(lst, cl, lst$port)
  pending = pair$client$write_async(data, timeout = 60)
  queued = promises::catch(pair$client$write_async("never sent", timeout = 60), identity)
  run_until(function() FALSE, 0.5)
  pair$client$close()
  cond = tryCatch(wait_for(pending, 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_closed")
  expect_gt(as.double(cond$bytes), 0)
  expect_lt(as.double(cond$bytes), size)
  cond = wait_for(queued, 10)
  expect_s3_class(cond, "tailcat_closed")
  expect_identical(as.double(cond$bytes), 0)
})

test_that("a latin1 string is written as UTF-8", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  text = iconv("café ü", "UTF-8", "latin1")
  expect_identical(Encoding(text), "latin1")
  expect_identical(pair$client$write(text), 8L)
  got = pair$server$read(timeout = 20, as = "text")
  expect_identical(got, "café ü")
  expect_identical(charToRaw(got), as.raw(c(0x63, 0x61, 0x66, 0xc3, 0xa9, 0x20, 0xc3, 0xbc)))
})

test_that("an operation started inside a private later loop completes on that loop", {
  map_url = silent_map_url()
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)), derp_map_url = map_url)
  on.exit(cl$close())
  state = new.env()
  later::with_temp_loop({
    pending = cl$ping_async(timeout = 0)
    promises::then(pending, function(v) state$value = v, function(e) state$error = e)
    deadline = Sys.time() + 10
    while (is.null(state$error) && is.null(state$value) && Sys.time() < deadline) {
      later::run_now(0.05)
    }
    state$inside = !is.null(state$error)
  })
  expect_true(state$inside)
  expect_s3_class(state$error, "tailcat_timeout")

  cl$close()
  later::with_temp_loop({
    pending = cl$ping_async()
    promises::then(pending, function(v) NULL, function(e) state$closed = e)
    deadline = Sys.time() + 10
    while (is.null(state$closed) && Sys.time() < deadline) {
      later::run_now(0.05)
    }
  })
  expect_s3_class(state$closed, "tailcat_closed")
})

test_that("an operation whose private loop is destroyed first completes on the global loop", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  state = new.env()
  later::with_temp_loop({
    pending = lst$accept_async(timeout = 0.5)
    promises::then(pending, function(v) state$value = v, function(e) state$error = e)
  })
  expect_null(state$error)
  expect_true(run_until(function() !is.null(state$error), 10))
  expect_s3_class(state$error, "tailcat_timeout")
})

test_that("read_all() and read_all_async() check max_bytes", {
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)))
  on.exit(cl$close())
  expect_identical(check_max_bytes(Inf), Inf)
  expect_identical(check_max_bytes(0L), 0)
  for (value in list(-1, 1.5, NA, NA_real_, NaN, "1", c(1, 2), numeric(0), -Inf, TRUE)) {
    expect_error(check_max_bytes(value), "max_bytes", class = "tailcat_invalid_argument")
  }
  expect_identical(read_all_chunk(Inf, 10), 65536)
  expect_identical(read_all_chunk(10, 0), 11)
  expect_identical(read_all_chunk(1e6, 0), 65536)
  expect_identical(read_all_chunk(1e6, 999990), 11)
  expect_match(too_long_headline(1e6), "(1,000,000 bytes)", fixed = TRUE)
  expect_match(too_long_headline(1), "(1 byte)", fixed = TRUE)
})

test_that("read_all() stops with tailcat_failure past max_bytes and leaves the rest of the stream readable", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("0123456789abcdef")
  pair$client$close_write()
  for (max_bytes in list(-1, 1.5, NA, "1", c(1, 2))) {
    expect_error(pair$server$read_all(max_bytes = max_bytes), class = "tailcat_invalid_argument")
    expect_error(pair$server$read_all_async(max_bytes = max_bytes), class = "tailcat_invalid_argument")
  }
  cond = tryCatch(pair$server$read_all(timeout = 20, max_bytes = 10), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_s3_class(cond, "tailcat_error")
  expect_identical(cond$status, 5L)
  expect_identical(cond$bytes, 11L)
  expect_match(conditionMessage(cond), "^The stream is longer than `max_bytes` \\(10 bytes\\)\\.")
  expect_match(conditionMessage(cond), "connection stays open", fixed = TRUE)
  expect_identical(deparse(conditionCall(cond)), "pair$server$read_all(timeout = 20, max_bytes = 10)")
  expect_false(pair$server$is_closed)
  expect_identical(pair$server$read_all(timeout = 20, as = "text"), "bcdef")

  pair = connect_pair(lst, cl, lst$port)
  big = as.raw(rep_len(0:255, 200000))
  pair$client$write(big)
  pair$client$close_write()
  cond = tryCatch(wait_for(pair$server$read_all_async(timeout = 30, max_bytes = 150000), 30), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 150001L)
  expect_match(conditionMessage(cond), "(150,000 bytes)", fixed = TRUE)
  expect_identical(pair$server$read_all(timeout = 20), big[150002:200000])

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("exactly")
  pair$client$close_write()
  expect_identical(wait_for(pair$server$read_all_async(timeout = 20, max_bytes = 7, as = "text"), 20), "exactly")

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("exactly")
  pair$client$close_write()
  expect_identical(pair$server$read_all(timeout = 20, max_bytes = 7, as = "text"), "exactly")

  pair = connect_pair(lst, cl, lst$port)
  pair$client$close_write()
  expect_identical(pair$server$read_all(timeout = 20, max_bytes = 0), raw(0))
})
