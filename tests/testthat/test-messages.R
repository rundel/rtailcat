test_that("message lengths are 4-byte unsigned big-endian", {
  expect_identical(encode_length(0), as.raw(c(0, 0, 0, 0)))
  expect_identical(encode_length(258), as.raw(c(0, 0, 1, 2)))
  expect_identical(encode_length(.Machine$integer.max), as.raw(c(0x7f, 0xff, 0xff, 0xff)))
  expect_identical(decode_length(as.raw(c(0, 0, 1, 2))), 258)
  expect_identical(decode_length(as.raw(c(0xff, 0xff, 0xff, 0xff))), 2^32 - 1)
  for (n in c(0, 1, 255, 256, 65536, 1e6, .Machine$integer.max)) {
    expect_identical(decode_length(encode_length(n)), as.double(n))
  }
})

test_that("the readers report what they consumed", {
  r = exact_reader(5)
  expect_null(r$start())
  expect_identical(r$want(), 5)
  expect_null(r$feed(as.raw(1:2)))
  expect_identical(r$want(), 3)
  expect_identical(r$feed(as.raw(3:5))$value, as.raw(1:5))

  expect_identical(exact_reader(0)$start()$value, raw(0))
  expect_identical(exact_reader(1e6)$want(), 65536)
  expect_identical(exact_reader(3)$feed(NULL), list(value = NULL))

  r = exact_reader(5)
  r$feed(as.raw(1:2))
  out = r$feed(NULL)
  expect_identical(out$error$bytes, 2L)
  expect_identical(out$error$headline, "The stream ended after 2 of 5 bytes.")

  r = message_reader(Inf)
  expect_identical(r$want(), 4)
  expect_null(r$feed(as.raw(c(0, 0))))
  expect_identical(r$want(), 2)
  expect_null(r$feed(as.raw(c(0, 3))))
  expect_identical(r$want(), 3)
  expect_null(r$feed(as.raw(1)))
  expect_identical(r$total(), 5)
  out = r$feed(NULL)
  expect_identical(out$error$bytes, 5L)
  expect_identical(out$error$headline, "The stream ended after 1 of the message's 3 bytes.")

  r = message_reader(10)
  out = r$feed(as.raw(c(0, 0, 0, 11)))
  expect_identical(out$error$bytes, 4L)
  expect_match(out$error$headline, "11 bytes, more than `max_bytes` (10)", fixed = TRUE)

  r = message_reader(Inf)
  out = r$feed(as.raw(c(0x80, 0, 0, 0)))
  expect_match(out$error$headline, "more than `max_bytes` (2,147,483,647)", fixed = TRUE)

  expect_identical(message_reader(Inf)$feed(as.raw(c(0, 0, 0, 0)))$value, raw(0))
  expect_identical(message_reader(Inf)$feed(NULL), list(value = NULL))
  r = message_reader(Inf)
  r$feed(as.raw(0))
  expect_identical(r$feed(NULL)$error$headline, "The stream ended in the middle of a message header.")
})

test_that("read_exact() reads exactly n bytes across chunks and returns NULL at a clean end", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, lst$port)
  big = as.raw(rep_len(0:255, 200000))
  pair$client$write(big)
  pair$client$write("tail")
  pair$client$close_write()
  expect_identical(pair$server$read_exact(150000, timeout = 20), big[1:150000])
  expect_identical(pair$server$read_exact(0, timeout = 20), raw(0))
  expect_identical(pair$server$read_exact(0, as = "text"), "")
  expect_identical(wait_for(pair$server$read_exact_async(50000, timeout = 20), 20), big[150001:200000])
  expect_identical(pair$server$read_exact(4, timeout = 20, as = "text"), "tail")
  expect_null(pair$server$read_exact(4, timeout = 20))
  expect_null(wait_for(pair$server$read_exact_async(4, timeout = 20), 20))

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("abc")
  pair$client$close_write()
  cond = tryCatch(pair$server$read_exact(5, timeout = 20), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 3L)
  expect_match(conditionMessage(cond), "^The stream ended after 3 of 5 bytes\\.")
  expect_identical(deparse(conditionCall(cond)), "pair$server$read_exact(5, timeout = 20)")

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("abc")
  cond = tryCatch(pair$server$read_exact(5, timeout = 1), error = identity)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(cond$bytes, 3L)
  expect_match(conditionMessage(cond), "trying to read 5 bytes", fixed = TRUE)

  pair$client$write("defgh")
  expect_identical(pair$server$read_exact(5, timeout = 0, as = "text"), "defgh")
  expect_error(pair$server$read_exact(1, timeout = 0), class = "tailcat_timeout")

  pending = pair$server$read_exact_async(10)
  tailcat_cancel(pending)
  expect_error(wait_for(pending, 20), class = "tailcat_canceled")

  expect_error(pair$server$read_exact(-1), "n", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_exact_async(1.5), "n", class = "tailcat_invalid_argument")
})

test_that("messages keep their boundaries in both directions", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  big = as.raw(rep_len(0:255, 300000))
  expect_identical(pair$client$write_message("hello"), 5L)
  pair$client$write_message(raw(0))
  pair$client$write_message(big)
  expect_identical(wait_for(pair$client$write_message_async(c("a", "b")), 20), 2L)

  expect_identical(pair$server$read_message(timeout = 20, as = "text"), "hello")
  expect_identical(pair$server$read_message(timeout = 20), raw(0))
  expect_identical(wait_for(pair$server$read_message_async(timeout = 20), 20), big)
  expect_identical(wait_for(pair$server$read_message_async(timeout = 20, as = "text"), 20), "ab")

  pair$server$write_message("reply")
  expect_identical(pair$client$read_message(timeout = 20, as = "text"), "reply")

  pair$client$write_message(serialize(list(a = 1, b = "x"), NULL))
  expect_identical(unserialize(pair$server$read_message(timeout = 20, max_bytes = 1e6)), list(a = 1, b = "x"))

  pair$client$write_message("wire")
  expect_identical(pair$server$read_exact(4, timeout = 20), as.raw(c(0, 0, 0, 4)))
  expect_identical(pair$server$read_exact(4, timeout = 20, as = "text"), "wire")

  pair$client$close_write()
  expect_null(pair$server$read_message(timeout = 20))
  expect_null(wait_for(pair$server$read_message_async(timeout = 20), 20))
})

test_that("read_message() refuses long messages before reading them and reports streams cut short", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write_message(as.raw(1:20))
  cond = tryCatch(pair$server$read_message(timeout = 20, max_bytes = 10), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 4L)
  expect_match(conditionMessage(cond), "^The message is 20 bytes, more than `max_bytes` \\(10\\)\\.")
  expect_match(conditionMessage(cond), "close the connection", fixed = TRUE)
  expect_identical(pair$server$read_exact(20, timeout = 20), as.raw(1:20))

  pair$client$write_message(as.raw(1:20))
  cond = tryCatch(wait_for(pair$server$read_message_async(timeout = 20, max_bytes = 19), 20), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 4L)

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write(c(encode_length(10), as.raw(1:3)))
  pair$client$close_write()
  cond = tryCatch(pair$server$read_message(timeout = 20), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 7L)
  expect_match(conditionMessage(cond), "^The stream ended after 3 of the message's 10 bytes\\.")

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write(as.raw(c(0, 0)))
  pair$client$close_write()
  cond = tryCatch(wait_for(pair$server$read_message_async(timeout = 20), 20), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$bytes, 2L)
  expect_match(conditionMessage(cond), "middle of a message header", fixed = TRUE)

  pair = connect_pair(lst, cl, lst$port)
  pair$client$write_message(as.raw(c(0x61, 0, 0x62)))
  expect_error(pair$server$read_message(timeout = 20, as = "text"), "NUL", class = "tailcat_invalid_argument")
})

test_that("the framing methods are TCP only and check their arguments", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port, network = "udp")
  for (call in list(
    quote(pair$client$read_exact(1)),
    quote(pair$client$read_exact_async(1)),
    quote(pair$client$read_message()),
    quote(pair$client$read_message_async()),
    quote(pair$client$write_message("x")),
    quote(pair$client$write_message_async("x")),
    quote(pair$client$read_loop(identity, messages = TRUE))
  )) {
    expect_error(eval(call), "only supported on TCP", class = "tailcat_invalid_argument")
  }

  lst = srv$listen(0)
  pair = connect_pair(lst, cl, lst$port)
  expect_error(pair$client$write_message(1), "data", class = "tailcat_invalid_argument")
  expect_error(pair$client$read_message(max_bytes = -1), "max_bytes", class = "tailcat_invalid_argument")
  expect_error(pair$client$read_message(as = "chr"), "as", class = "tailcat_invalid_argument")
})
