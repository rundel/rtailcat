test_that("a failed duplicate listen leaves the server started and its listeners working", {
  # from internal/capi/e2e_test.go: TestE2EListenFailureKeepsServerStarted; listen_test.go: TestListen
  skip_relay()
  srv = relay_server()
  tcp = srv$listen(0)
  port = tcp$port
  expect_gt(port, 0L)
  expect_error(srv$listen(port), class = "tailcat_failure")
  udp = srv$listen(port, network = "udp")
  expect_identical(udp$port, port)
  expect_error(srv$listen(port, network = "udp"), class = "tailcat_failure")
  expect_identical(srv$start(), srv)
  expect_type(srv$info()$address, "character")

  info = srv$info()
  expect_named(info, c("address", "ip", "public_key"), ignore.order = TRUE)
  host = info$ip
  expect_identical(tcp$local_address, paste0("[", host, "]:", port))
  expect_identical(tcp$info()$network, "tcp")
  expect_identical(udp$info()$network, "udp")

  cl = relay_client(srv$address)
  pair = connect_pair(tcp, cl, port)
  pair$client$write("tcp")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "tcp")
  upair = connect_pair(udp, cl, port, network = "udp")
  upair$client$write("udp")
  expect_identical(rawToChar(upair$server$read(timeout = 20)), "udp")
})

test_that("closing a listener keeps accepted connections open and frees the port for reuse", {
  # from listen_test.go: TestListen (closing a listener); cmd/libtailcat/tailcat.h: tc_listener_accept
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  port = lst$port
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, port)

  lst$close()
  expect_identical(lst$close(), lst)
  expect_error(lst$accept(timeout = 1), class = "tailcat_closed")
  expect_false(pair$server$is_closed)
  pair$client$write("after close")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "after close")
  pair$server$write("reply")
  expect_identical(rawToChar(pair$client$read(timeout = 20)), "reply")

  expect_error(cl$dial(port, timeout = 10), class = "tailcat_failure")
  again = srv$listen(port)
  expect_identical(again$port, port)
  pair2 = connect_pair(again, cl, port)
  pair2$client$write("reused")
  expect_identical(rawToChar(pair2$server$read(timeout = 20)), "reused")
})

test_that("closing a client ends its dialed connections and the server sees end of stream", {
  # from internal/capi/e2e_test.go: TestE2ECloseServerRetiresTree, mirrored for the client side
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)
  pending = pair$client$read_async(timeout = Inf)
  later::run_now(0.1)

  cl$close()
  expect_true(pair$client$is_closed)
  expect_error(wait_for(pending, 10), class = "tailcat_closed")
  expect_error(pair$client$write("x"), class = "tailcat_closed")
  # Racy by nature: close() does not drain, so the end of stream usually, but
  # not always, reaches the server before its read times out.
  res = tryCatch(pair$server$read(timeout = 3), error = function(e) e)
  expect_true(is.null(res) || inherits(res, "tailcat_timeout"))
  expect_false(pair$server$is_closed)
})

test_that("a client can drain before and after pinging and reports its public key", {
  # from internal/capi/e2e_test.go: TestE2EClientPingAndInfo
  skip_relay()
  srv = relay_server()
  srv$start()
  keys = tailcat_keygen()
  cl = relay_client(srv$address, key = keys)
  expect_invisible(cl$drain(timeout = 5))
  expect_gte(cl$ping(timeout = 20), 0L)
  expect_identical(cl$info()$public_key, keys$public_key)
  expect_invisible(cl$drain(timeout = 5))
})
