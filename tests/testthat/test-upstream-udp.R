test_that("a UDP read timeout leaves the flow usable for later datagrams", {
  # from internal/capi/e2e_test.go: TestE2EUDPRoundTripAndDeadline
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port, network = "udp")

  pair$server$write("world")
  expect_identical(rawToChar(pair$client$read(timeout = 20)), "world")
  expect_error(pair$client$read(timeout = 0.1), class = "tailcat_timeout")
  pair$server$write("again")
  expect_identical(rawToChar(pair$client$read(timeout = 20)), "again")
  expect_error(pair$client$close_write(), class = "tailcat_invalid_argument")
  expect_error(pair$client$write(raw(1233)), class = "tailcat_invalid_argument")
})

test_that("each UDP client gets its own flow whose addresses match both ends", {
  # from tailcat_test.go: TestUDP
  skip_relay()
  srv = relay_server()
  srv$start()
  lst = srv$listen(5353, network = "udp")
  host = srv$info()$ip
  clients = list(relay_client(srv$address), relay_client(srv$address))

  for (cl in clients) {
    pair = connect_pair(lst, cl, 5353, network = "udp")
    expect_identical(pair$server$local_address, paste0("[", host, "]:5353"))
    expect_identical(pair$server$remote_address, pair$client$local_address)
    expect_identical(pair$client$remote_address, pair$server$local_address)
    for (payload in list(charToRaw("small datagram"), as.raw(rep(0x6d, 1232)))) {
      pair$client$write(payload)
      echo = pair$server$read(n = length(payload) + 1, timeout = 20)
      expect_identical(echo, payload)
      pair$server$write(echo)
      expect_identical(pair$client$read(n = length(payload) + 1, timeout = 20), payload)
    }
  }
})

test_that("two UDP dials from one client are accepted as separate flows", {
  # from tailcat_test.go: TestUDP (one handler call per flow)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  a = connect_pair(lst, cl, lst$port, network = "udp")
  b = connect_pair(lst, cl, lst$port, network = "udp")
  expect_false(identical(a$client$local_address, b$client$local_address))
  a$client$write("to a")
  b$client$write("to b")
  expect_identical(rawToChar(b$server$read(timeout = 20)), "to b")
  expect_identical(rawToChar(a$server$read(timeout = 20)), "to a")
})

test_that("datagrams to a UDP port nobody listens on are silently dropped", {
  # from tailcat_test.go: TestUDP (filtered port 54)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  unused = if (lst$port == 65535L) 65534L else lst$port + 1L
  conn = cl$dial(unused, network = "udp", timeout = 30)
  expect_identical(conn$write("drop me"), 7L)
  expect_error(conn$read(timeout = 0.5), class = "tailcat_timeout")
  expect_error(lst$accept(timeout = 0.2), class = "tailcat_timeout")
})

test_that("an idle UDP flow ends on the server after udp_idle_timeout, unless kept busy", {
  # from tailcat_test.go: TestUDPIdleTimeout, TestUDPIdleTimeoutReset
  skip_relay()
  srv = relay_server(udp_idle_timeout = 1)
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port, network = "udp")

  for (msg in c("a", "b", "c", "d", "e")) {
    pair$client$write(msg)
    expect_identical(rawToChar(pair$server$read(timeout = 5)), msg)
    Sys.sleep(0.35)
  }

  started = Sys.time()
  expect_null(pair$server$read(timeout = 10))
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)
  expect_error(pair$server$write("late"), class = "tailcat_error")

  pending = lst$accept_async(timeout = 20)
  pair$client$write("new flow")
  fresh = wait_for(pending, 25)
  expect_identical(rawToChar(fresh$read(timeout = 10)), "new flow")
  expect_identical(fresh$remote_address, pair$client$local_address)
})

test_that("a zero-byte UDP read fails and drops the datagram (upstream bug, pinned)", {
  # from cmd/libtailcat/tailcat.h: tc_conn_read (UDP truncates to capacity; capacity zero allowed)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port, network = "udp")
  pair$client$write("dropped")
  pair$client$write("kept")
  # TODO: waiting on an upstream fix (notes/upstream_issues.md, Known issues in CLAUDE.md). tailcat's capi passes the empty buffer to gVisor, which fails with "bad buffer" (tailcat_failure) and still discards the datagram. This pins today's behavior so the test fails once the pinned tailcat commit includes a fix; then update the expectations below to whatever upstream settled on. tailcat.h does not define a zero-capacity UDP read, so the fix may be a no-op like TCP (read(n = 0) returns raw(0) at once and the next read returns "dropped"), truncation to zero bytes (read(n = 0) returns raw(0) and consumes "dropped"), or a rejection that leaves the datagram in place (an invalid argument error, and the next read returns "dropped").
  expect_error(pair$server$read(n = 0, timeout = 20), "bad buffer", class = "tailcat_failure")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "kept")
})
