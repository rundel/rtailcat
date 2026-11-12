test_that("TCP echo works in both directions and close_write signals EOF", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8080)
  expect_s3_class(lst, "TailcatListener")
  expect_identical(lst$port, 8080L)
  expect_identical(lst$network, "tcp")
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, 8080)
  cc = pair$client
  sc = pair$server
  expect_s3_class(cc, "TailcatConnection")
  expect_s3_class(sc, "TailcatConnection")
  expect_identical(cc$network, "tcp")
  expect_identical(cc$remote_address, sc$local_address)
  expect_identical(cc$local_address, sc$remote_address)

  expect_identical(cc$write("hello "), 6L)
  cc$write(charToRaw("server"))
  cc$close_write()
  expect_identical(rawToChar(sc$read_all(timeout = 20)), "hello server")
  expect_null(sc$read(timeout = 5))

  expect_invisible(sc$write(c("hello ", "client")))
  sc$close_write()
  expect_identical(rawToChar(cc$read_all(timeout = 20)), "hello client")
  expect_null(cc$read(timeout = 5))
  expect_true(cc$readable())

  cc$close()
  sc$close()
  expect_true(cc$is_closed)
  expect_error(cc$read(), class = "tailcat_closed")
  expect_invisible(cl$drain(timeout = 5))
  expect_invisible(srv$drain(timeout = 5))
})

test_that("async reads and writes resolve through the event loop", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  port = lst$port
  expect_true(is.integer(port) && port > 0)
  cl = relay_client(srv$address)

  pending_accept = lst$accept_async(timeout = 30)
  pending_dial = cl$dial_async(port, timeout = 30)
  sc = wait_for(pending_accept, 40)
  cc = wait_for(pending_dial, 40)

  pending_read = sc$read_async(timeout = 20)
  expect_identical(wait_for(cc$write_async("async"), 20), 5L)
  expect_identical(rawToChar(wait_for(pending_read, 20)), "async")

  pending_all = cc$read_all_async(timeout = 20)
  payload = as.raw(sample(0:255, 200000, replace = TRUE))
  sc$write(payload)
  wait_for(sc$close_write_async(), 20)
  expect_identical(wait_for(pending_all, 30), payload)

  info = wait_for(cc$info_async(), 10)
  expect_identical(info$network, "tcp")
  expect_type(wait_for(srv$info_async(), 10)$address, "character")
  cc$close()
  sc$close()
  expect_identical(wait_for(cl$drain_async(), 10), cl)
})

test_that("timeouts raise tailcat_timeout and leave handles usable", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8081)
  cl = relay_client(srv$address)

  expect_error(lst$accept(timeout = 0.2), class = "tailcat_timeout")
  expect_error(wait_for(lst$accept_async(timeout = 0.2), 10), class = "tailcat_timeout")

  pair = connect_pair(lst, cl, 8081)
  cond = tryCatch(pair$client$read(timeout = 0.2), error = function(e) e)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(cond$status, 3L)

  pair$server$write("still open")
  expect_identical(rawToChar(pair$client$read(timeout = 20)), "still open")

  pair$server$close_write()
  pair$client$write("partial")
  cond = tryCatch(pair$server$read_all(timeout = 0.5), error = function(e) e)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(as.double(cond$bytes), 7)

  pair$client$write("more")
  cond = tryCatch(wait_for(pair$server$read_all_async(timeout = 0.5), 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(as.double(cond$bytes), 4)
})

test_that("closing a listener ends a pending async accept with tailcat_closed", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8082)
  pending = lst$accept_async()
  later::run_now(0.2)
  lst$close()
  expect_true(lst$is_closed)
  expect_false(srv$is_closed)
  expect_error(wait_for(pending, 10), class = "tailcat_closed")
  expect_error(lst$accept(timeout = 1), class = "tailcat_closed")
})

test_that("closing the server closes its listeners and connections", {
  skip_relay()
  srv = TailcatServer$new(region = relay_region())
  on.exit(srv$close())
  lst = srv$listen(8083)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 8083)
  pending_read = pair$client$read_async(timeout = 30)
  pending_accept = lst$accept_async()
  srv$close()
  expect_true(srv$is_closed)
  expect_true(lst$is_closed)
  expect_true(pair$server$is_closed)
  expect_false(pair$client$is_closed)
  expect_error(pair$server$read(timeout = 1), class = "tailcat_closed")
  expect_error(wait_for(pending_accept, 10), class = "tailcat_closed")
  cl$close()
  expect_true(pair$client$is_closed)
  # Racy by nature: the end of stream from the server's teardown may or may not
  # reach the client before the client itself is closed.
  res = tryCatch(wait_for(pending_read, 10), error = function(e) e)
  expect_true(is.null(res) || inherits(res, "tailcat_closed"))
})

test_that("serve() runs the handler for each connection and reports errors", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8084)
  cl = relay_client(srv$address)

  state = new.env()
  state$handled = 0L
  state$errors = list()
  expect_identical(lst$serve(
    function(conn) {
      msg = conn$read_all(timeout = 20, as = "text")
      if (msg == "fail") {
        stop("handler failed on purpose")
      }
      conn$write(toupper(msg))
      conn$close_write()
      state$handled = state$handled + 1L
    },
    on_error = function(cond, conn) {
      state$errors[[length(state$errors) + 1L]] = list(cond = cond, conn = conn)
    }
  ), lst)
  expect_error(lst$serve(function(conn) NULL), "already serving", class = "tailcat_failure")
  expect_match(printed(lst), "serving", fixed = TRUE)

  for (word in c("one", "two")) {
    conn = cl$dial(8084, timeout = 30)
    conn$write(word)
    conn$close_write()
    target = match(word, c("one", "two"))
    expect_true(run_until(function() state$handled >= target, 30))
    expect_identical(conn$read_all(timeout = 20, as = "text"), toupper(word))
    conn$close()
  }

  conn = cl$dial(8084, timeout = 30)
  conn$write("fail")
  conn$close_write()
  expect_true(run_until(function() length(state$errors) == 1L, 30))
  expect_match(conditionMessage(state$errors[[1]]$cond), "on purpose")
  expect_true(state$errors[[1]]$conn$is_closed)
  conn$close()

  lst$close()
  later::run_now(0.5)
  expect_false(grepl("serving", printed(lst), fixed = TRUE))
})

test_that("serve() without on_error turns handler errors into warnings", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8085)
  cl = relay_client(srv$address)
  lst$serve(function(conn) stop("no handler for you"))
  conn = cl$dial(8085, timeout = 30)
  expect_warning(
    run_until(function() FALSE, 3),
    "no handler for you"
  )
  conn$close()
})

test_that("UDP datagrams are exchanged as whole messages", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(9000, network = "udp")
  expect_identical(lst$network, "udp")
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, 9000, network = "udp")
  cc = pair$client
  sc = pair$server
  expect_identical(cc$network, "udp")
  expect_identical(sc$network, "udp")

  cc$write("first")
  cc$write("second")
  expect_identical(rawToChar(sc$read(timeout = 20)), "first")
  expect_identical(rawToChar(sc$read(timeout = 20)), "second")

  sc$write(raw(0))
  expect_identical(cc$read(timeout = 20), raw(0))
  sc$write(as.raw(1:10))
  expect_identical(cc$read(n = 4, timeout = 20), as.raw(1:4))

  big = as.raw(rep(7L, 1232))
  expect_identical(cc$write(big), 1232L)
  expect_identical(sc$read(timeout = 20), big)
  expect_error(cc$write(raw(1233)), class = "tailcat_invalid_argument")
  expect_error(cc$read_all(), "only supported on TCP", class = "tailcat_invalid_argument")
  expect_error(cc$readable(), "only supported on TCP", class = "tailcat_invalid_argument")
  expect_error(cc$close_write(), "only supported on TCP", class = "tailcat_invalid_argument")
  expect_error(cc$close_write_async(), "only supported on TCP", class = "tailcat_invalid_argument")
  expect_error(cc$read_all_async(), "only supported on TCP", class = "tailcat_invalid_argument")
})

test_that("ping and disco_ping report latency", {
  skip_relay()
  srv = relay_server()
  srv$start()
  cl = relay_client(srv$address)

  secs = cl$ping(timeout = 30)
  expect_type(secs, "double")
  expect_gte(secs, 0)
  expect_lt(secs, 30)
  expect_equal(secs * 1000, round(secs * 1000))
  expect_type(wait_for(cl$ping_async(timeout = 30), 40), "double")

  dp = cl$disco_ping(timeout = 30)
  expect_setequal(names(dp), c("latency", "endpoint", "relay_region_id", "relay_region_code"))
  expect_type(dp$relay_region_id, "integer")
  expect_type(dp$latency, "double")
  expect_type(dp$endpoint, "character")
  expect_named(wait_for(cl$disco_ping_async(timeout = 30), 40), names(dp), ignore.order = TRUE)
})

test_that("address_resolve returns a usable address", {
  skip_relay()
  srv = relay_server()
  srv$start()
  resolved = tailcat_address_resolve(srv$address, derp_map_url = relay_derp_map_url(), timeout = 30)
  expect_type(resolved, "character")
  expect_identical(tailcat_address_parse(resolved)$public_key, srv$public_key)
  expect_identical(wait_for(tailcat_address_resolve_async(srv$address, derp_map_url = relay_derp_map_url(), timeout = 30), 40), resolved)

  lst = srv$listen(8087)
  cl = relay_client(resolved)
  pair = connect_pair(lst, cl, 8087)
  pair$client$write("resolved")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "resolved")
})

test_that("print methods never reveal addresses or keys", {
  skip_relay()
  keys = tailcat_keygen()
  ckeys = tailcat_keygen()
  srv = relay_server(key = keys)
  lst = srv$listen(8088)
  address = srv$address
  cl = relay_client(address, key = ckeys)
  pair = connect_pair(lst, cl, 8088)

  secrets = c(address, keys$private_key, keys$preshared_key, ckeys$private_key, sub("^[a-z]+:", "", c(keys$private_key, keys$preshared_key, ckeys$private_key)))
  outputs = c(
    printed(srv), printed(cl), printed(lst), printed(pair$client), printed(pair$server), printed(keys), printed(ckeys),
    utils::capture.output(print(srv$info()$public_key))
  )
  for (secret in secrets) {
    expect_false(any(grepl(secret, outputs, fixed = TRUE)))
  }
  expect_match(printed(srv), keys$public_key, fixed = TRUE)
  expect_match(printed(cl), ckeys$public_key, fixed = TRUE)
  expect_match(printed(lst), "8088", fixed = TRUE)
  srv$close()
  cl$close()
  for (x in list(srv, cl, lst, pair$client, pair$server)) {
    out = printed(x)
    expect_match(out, "closed", fixed = TRUE)
    expect_false(any(vapply(secrets, grepl, logical(1), x = out, fixed = TRUE)))
  }
})

test_that("reads return text with as = \"text\" over TCP", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8089)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 8089)
  cc = pair$client
  sc = pair$server

  cc$write("café ☃")
  got = sc$read(timeout = 20, as = "text")
  expect_identical(got, "café ☃")
  expect_identical(Encoding(got), "UTF-8")
  cc$write("raw")
  expect_identical(sc$read(timeout = 20), charToRaw("raw"))
  cc$write("async")
  expect_identical(wait_for(sc$read_async(timeout = 20, as = "text"), 20), "async")

  expect_error(sc$read(as = "string"), class = "tailcat_invalid_argument")
  expect_error(sc$read_all(as = NA_character_), class = "tailcat_invalid_argument")
  expect_error(sc$read_async(as = 1), class = "tailcat_invalid_argument")
  expect_error(sc$read_all_async(as = "utf8"), class = "tailcat_invalid_argument")

  cc$write(as.raw(c(0x61, 0x00, 0x62)))
  expect_error(sc$read(timeout = 20, as = "text"), "NUL", class = "tailcat_invalid_argument")

  pending = sc$read_all_async(as = "text")
  cc$write("one ü")
  cc$write(" two")
  cc$close_write()
  expect_identical(wait_for(pending, 20), "one ü two")
  expect_null(sc$read(timeout = 5, as = "text"))

  sc$close_write()
  expect_identical(cc$read_all(timeout = 20, as = "text"), "")
  expect_null(cc$read(timeout = 5, as = "text"))
})

test_that("UDP datagrams can be read as text", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(9001, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 9001, network = "udp")

  pair$client$write("datagram é")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "datagram é")
  pair$server$write(raw(0))
  expect_identical(pair$client$read(timeout = 20, as = "text"), "")
  pair$server$write("reply")
  expect_identical(wait_for(pair$client$read_async(timeout = 20, as = "text"), 20), "reply")
  pair$server$write("bytes")
  expect_identical(pair$client$read(timeout = 20, as = "raw"), charToRaw("bytes"))
})
