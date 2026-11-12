wait_close_write = function(conn, n) {
  promises::then(conn$close_write_async(timeout = 30), function(x) n)
}

test_that("data written before a full close() reaches the peer, followed by end of stream", {
  # from internal/capi/e2e_test.go: TestE2ETCPRoundTripAndHalfClose
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  expect_identical(pair$client$write("ping"), 4L)
  pair$client$close_write()
  expect_identical(rawToChar(pair$server$read_all(timeout = 20)), "ping")
  expect_true(pair$server$readable())

  expect_identical(pair$server$write("pong"), 4L)
  pair$server$close()
  expect_identical(rawToChar(pair$client$read_all(timeout = 20)), "pong")
  pair$client$close()
  expect_invisible(cl$drain(timeout = 5))
})

test_that("a pending async read is ended by close() and the handle stays closed", {
  # from internal/capi/api_test.go: TestCloseUnblocksReadAndRejectsStaleHandle
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  pending = pair$server$read_async(timeout = Inf)
  later::run_now(0.2)
  pair$server$close()
  expect_error(wait_for(pending, 5), class = "tailcat_closed")
  expect_error(pair$server$write("x"), class = "tailcat_closed")
  expect_error(pair$server$read(timeout = 1), class = "tailcat_closed")
  expect_null(pair$client$read(timeout = 20))
})

test_that("a read queued behind a pending read times out, and the pending read still gets the data", {
  # from internal/capi/api_test.go: TestDeadlineIncludesWaitingForAnotherRead, TestCancelledReadDoesNotPoisonNextRead
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  pending = pair$server$read_async(timeout = 30)
  later::run_now(0.1)
  started = Sys.time()
  expect_error(pair$server$read(timeout = 0.3), class = "tailcat_timeout")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)

  pair$client$write("first")
  expect_identical(rawToChar(wait_for(pending, 20)), "first")
  pair$client$write("second")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "second")
})

test_that("readable() never consumes buffered data and turns TRUE at end of stream", {
  # from internal/capi/api_test.go: TestReadabilityDoesNotConsumePayload, TestReadabilityReportsPeerEOF
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  expect_false(pair$client$readable())
  pair$server$write("hello")
  expect_true(run_until(function() pair$client$readable(), 20))
  expect_true(pair$client$readable())
  expect_identical(rawToChar(pair$client$read(n = 5, timeout = 5)), "hello")
  expect_false(pair$client$readable())

  pair$server$close_write()
  expect_true(run_until(function() pair$client$readable(), 20))
  expect_null(pair$client$read(timeout = 5))
  expect_true(pair$client$readable())
})

test_that("zero-byte TCP reads and writes succeed without signaling end of stream", {
  # from cmd/libtailcat/tailcat.h: tc_conn_read (zero-capacity TCP read is not an EOF probe)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  expect_identical(pair$client$read(n = 0, timeout = 1), raw(0))
  expect_identical(pair$client$write(raw(0)), 0L)
  pair$server$close_write()
  expect_true(run_until(function() pair$client$readable(), 20))
  expect_identical(pair$client$read(n = 0, timeout = 1), raw(0))
  expect_null(pair$client$read(timeout = 5))
})

test_that("large payloads cross in both directions at once without corruption", {
  # from cmd/libtailcat/tailcat.h: one read plus one write may run concurrently (no upstream bulk-transfer test)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  up = as.raw(sample(0:255, 1e6, replace = TRUE))
  down = as.raw(sample(0:255, 1e6, replace = TRUE))
  got_up = pair$server$read_all_async(timeout = 60)
  got_down = pair$client$read_all_async(timeout = 60)
  sent_up = promises::then(pair$client$write_async(up, timeout = 60), function(n) wait_close_write(pair$client, n))
  sent_down = promises::then(pair$server$write_async(down, timeout = 60), function(n) wait_close_write(pair$server, n))
  expect_equal(wait_for(sent_up, 70), length(up))
  expect_equal(wait_for(sent_down, 70), length(down))
  expect_identical(wait_for(got_up, 70), up)
  expect_identical(wait_for(got_down, 70), down)
})

test_that("concurrent connections from one or more clients keep their streams separate", {
  # from tailcat_test.go: TestUDP (two clients), applied to TCP streams on one listener
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  port = lst$port
  cl1 = relay_client(srv$address)
  cl2 = relay_client(srv$address)

  pairs = list(connect_pair(lst, cl1, port), connect_pair(lst, cl1, port), connect_pair(lst, cl2, port))
  locals = vapply(pairs, function(p) p$client$local_address, "")
  expect_identical(anyDuplicated(locals), 0L)
  for (p in pairs) {
    expect_identical(p$server$remote_address, p$client$local_address)
  }

  msgs = c("alpha", "bravo", "charlie")
  reads = lapply(pairs, function(p) p$server$read_all_async(timeout = 30))
  for (i in rev(seq_along(pairs))) {
    pairs[[i]]$client$write(msgs[[i]])
  }
  for (i in seq_along(pairs)) {
    pairs[[i]]$client$write(toupper(msgs[[i]]))
    pairs[[i]]$client$close_write()
  }
  got = vapply(reads, function(r) rawToChar(wait_for(r, 40)), "")
  expect_identical(got, paste0(msgs, toupper(msgs)))

  pairs[[1]]$client$close()
  pairs[[2]]$server$write("still here")
  expect_identical(rawToChar(pairs[[2]]$client$read(timeout = 20)), "still here")
})

test_that("dialing a TCP port nobody listens on fails fast instead of hanging", {
  # from tailcat_test.go: TestHalfClose (filtered port 81); the C ABI server refuses rather than drops
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)
  unused = if (lst$port == 65535L) 65534L else lst$port + 1L

  started = Sys.time()
  expect_error(cl$dial(unused, timeout = 10), class = "tailcat_failure")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 9)
  pair$client$write("ok")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "ok")
})

test_that("info() after both sides half-close panics inside tailcat (upstream bug, pinned)", {
  # from cmd/libtailcat/tailcat.h: tc_info (connection: local_address, remote_address, network)
  skip_relay()
  skip_if_not_installed("processx")
  # Run in a child process: the Go runtime prints the panic's stack trace to
  # standard error, which would otherwise clutter the test output.
  child = child_r(c(
    "srv = TailcatServer$new(region = region)",
    "lst = srv$listen(0)",
    "cl = TailcatClient$new(srv$address, derp_map_url = derp_map_url)",
    "pending = lst$accept_async(timeout = 30)",
    "cc = cl$dial(lst$port, timeout = 30)",
    "sc = NULL",
    "promises::then(pending, function(conn) sc <<- conn)",
    "deadline = Sys.time() + 30",
    "while (is.null(sc) && Sys.time() < deadline) later::run_now(0.05)",
    "cc$close_write()",
    "stopifnot(is.null(sc$read(timeout = 20)))",
    "sc$close_write()",
    "stopifnot(is.null(cc$read(timeout = 20)))",
    "deadline = Sys.time() + 10",
    "repeat {",
    "  res = tryCatch({ sc$info(timeout = 5); 'ok' }, error = function(e) paste(class(e)[1], conditionMessage(e)))",
    "  if (res != 'ok' || Sys.time() > deadline) break",
    "  Sys.sleep(0.1)",
    "}",
    "cat('RESULT', res, '\\n')",
    "srv$close()",
    "cl$close()"
  ))
  out = child_finish(child, timeout = 90)
  # The message has a headline and a detail line, so join the lines first.
  stdout = gsub("[[:space:]]+", " ", paste(out$stdout, collapse = " "))
  result = regmatches(stdout, regexpr("RESULT .*$", stdout))
  expect_length(result, 1)
  # TODO: waiting on an upstream fix (notes/upstream_issues.md, Known issues in CLAUDE.md). Once both directions are shut down, gVisor's TCPConn.RemoteAddr() returns nil and tailcat's Info() dereferences it; the guard recovers the panic and returns TC_FAILURE. When the pinned tailcat commit includes a fix, this test fails: change it to expect "RESULT ok" and an empty standard error.
  expect_match(result, "tailcat_failure .*nil pointer dereference")
  expect_true(any(grepl("libtailcat: internal failure", out$stderr, fixed = TRUE)))
})
