test_that("back-to-back write_async() calls arrive in the order they were made", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  msgs = formatC(seq_len(500), width = 4, flag = "0")
  pending = lapply(msgs, function(m) pair$client$write_async(paste0(m, ";")))
  last = pending[[length(pending)]]
  expect_identical(wait_for(last, 60), 5L)
  pair$client$close_write()
  got = pair$server$read_all(timeout = 60, as = "text")
  expect_identical(got, paste0(msgs, ";", collapse = ""))
})

test_that("several read_async() calls in flight receive consecutive chunks in order", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  msgs = formatC(seq_len(40), width = 4, flag = "0")
  pending = lapply(msgs, function(m) pair$server$read_async(n = 4, timeout = 60, as = "text"))
  for (m in msgs) {
    pair$client$write(m)
    later::run_now(0.01)
  }
  got = vapply(pending, function(p) wait_for(p, 30), "")
  expect_identical(got, msgs)
})

test_that("a canceled or timed-out queued read ends promptly without disturbing its neighbors", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  first = pair$server$read_async(timeout = 60, as = "text")
  second = pair$server$read_async(timeout = 60, as = "text")
  third = pair$server$read_async(timeout = 0.3, as = "text")
  fourth = pair$server$read_async(timeout = 60, as = "text")
  later::run_now(0.1)

  started = Sys.time()
  expect_true(attr(second, "rtailcat_cancel")())
  expect_error(wait_for(second, 10), class = "tailcat_canceled")
  expect_error(wait_for(third, 10), class = "tailcat_timeout")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)

  pair$client$write("one")
  expect_identical(wait_for(first, 20), "one")
  pair$client$write("two")
  expect_identical(wait_for(fourth, 20), "two")
})

test_that("a queued operation's deadline counts from when it was started", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  blocker = pair$server$read_async(timeout = 3)
  started = Sys.time()
  queued = pair$server$read_async(timeout = 0.4)
  expect_error(wait_for(queued, 10), class = "tailcat_timeout")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 2)
  expect_error(wait_for(blocker, 10), class = "tailcat_timeout")
})

test_that("closing a connection ends every queued operation with tailcat_closed", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  reads = lapply(1:3, function(i) promises::catch(pair$server$read_async(timeout = 60), identity))
  later::run_now(0.1)
  started = Sys.time()
  pair$server$close()
  for (p in reads) {
    expect_s3_class(wait_for(p, 10), "tailcat_closed")
  }
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)
})

test_that("a read and a write on one connection still run at the same time", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  pending = pair$client$read_async(timeout = 30, as = "text")
  queued = pair$client$read_async(timeout = 30, as = "text")
  later::run_now(0.1)
  expect_identical(pair$client$write("ping"), 4L)
  expect_identical(wait_for(pair$client$write_async("pong"), 10), 4L)
  cond = tryCatch(pair$server$read_all(timeout = 1), error = function(e) e)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(as.double(cond$bytes), 8)
  pair$server$write("a")
  expect_identical(wait_for(pending, 10), "a")
  pair$server$write("b")
  expect_identical(wait_for(queued, 10), "b")
})
