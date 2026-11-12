elapsed = function(started) {
  as.double(Sys.time() - started, units = "secs")
}

test_that("a TCP read with timeout = 0 returns data that has arrived, every time", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  for (i in 1:50) {
    msg = paste0("chunk ", i)
    pair$client$write(msg)
    expect_true(run_until(function() pair$server$readable(), 20))
    expect_identical(pair$server$read(timeout = 0, as = "text"), msg)
  }
  pair$client$write("async")
  expect_true(run_until(function() pair$server$readable(), 20))
  expect_identical(wait_for(pair$server$read_async(timeout = 0, as = "text"), 10), "async")
  expect_identical(pair$server$read(n = 0, timeout = 0), raw(0))
})

test_that("a poll with nothing to read raises tailcat_timeout at once and leaves the connection usable", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  started = Sys.time()
  cond = tryCatch(pair$server$read(timeout = 0), error = identity)
  expect_lt(elapsed(started), 1)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(cond$bytes, 0L)
  expect_match(conditionMessage(cond), "^Could not read without waiting \\(`timeout = 0`\\)\\.")
  expect_error(wait_for(pair$server$read_async(timeout = 0), 10), class = "tailcat_timeout")

  pair$client$write("later")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "later")
  pair$client$close_write()
  expect_true(run_until(function() pair$server$readable(), 20))
  expect_null(pair$server$read(timeout = 0))
})

test_that("a poll queued behind a pending read does not wait for it", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  blocker = pair$server$read_async(timeout = 30, as = "text")
  later::run_now(0.1)
  started = Sys.time()
  expect_error(pair$server$read(timeout = 0), class = "tailcat_timeout")
  expect_error(wait_for(pair$server$read_async(timeout = 0), 10), class = "tailcat_timeout")
  expect_lt(elapsed(started), 2)

  pair$client$write("first")
  expect_identical(wait_for(blocker, 20), "first")
})

test_that("read_all() with timeout = 0 returns a stream that has fully arrived", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  pair$client$write("whole stream")
  pair$client$close_write()
  expect_true(run_until(function() pair$server$readable(), 20))
  run_until(function() FALSE, 1)
  expect_identical(pair$server$read_all(timeout = 0, as = "text"), "whole stream")
})

test_that("writes, accepts, UDP reads, and info poll with timeout = 0", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  started = Sys.time()
  expect_error(lst$accept(timeout = 0), class = "tailcat_timeout")
  expect_lt(elapsed(started), 1)
  cc = cl$dial(lst$port, timeout = 30)
  sc = NULL
  expect_true(run_until(function() {
    if (is.null(sc)) {
      sc <<- tryCatch(lst$accept(timeout = 0), tailcat_timeout = function(e) NULL)
    }
    !is.null(sc)
  }, 20))
  expect_s3_class(sc, "TailcatConnection")
  expect_identical(cc$write("x", timeout = 0), 1L)
  expect_identical(sc$read(timeout = 20, as = "text"), "x")
  expect_named(sc$info(timeout = 0), c("local_address", "network", "remote_address"), ignore.order = TRUE)

  ulst = srv$listen(0, network = "udp")
  upair = connect_pair(ulst, cl, ulst$port, network = "udp")
  expect_error(upair$server$read(timeout = 0), class = "tailcat_timeout")
  upair$client$write("datagram")
  got = NULL
  expect_true(run_until(function() {
    if (is.null(got)) {
      got <<- tryCatch(upair$server$read(timeout = 0, as = "text"), tailcat_timeout = function(e) NULL)
    }
    !is.null(got)
  }, 20))
  expect_identical(got, "datagram")
})
