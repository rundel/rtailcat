expect_echo = function(listener, client, text) {
  pair = connect_pair(listener, client, listener$port, timeout = 20)
  pair$client$write(text)
  expect_identical(rawToChar(pair$server$read(timeout = 20)), text)
  pair$client$close()
  pair$server$close()
}

test_that("allowed_clients admits only listed keys and allow_client() adds to the list", {
  # from internal/capi/api_test.go: TestAllowClientKeepsAllowlistSemantics
  skip_relay()
  k1 = tailcat_keygen()
  k2 = tailcat_keygen()
  k3 = tailcat_keygen()
  srv = relay_server(allowed_clients = k1$public_key)
  lst = srv$listen(0)

  expect_echo(lst, relay_client(srv$address, key = k1), "k1")

  stranger = relay_client(srv$address, key = k2)
  expect_error(stranger$dial(lst$port, timeout = 3), class = "tailcat_timeout")

  expect_identical(srv$allow_client(k3$public_key), srv)
  k3_client = relay_client(srv$address, key = k3)
  expect_identical(k3_client$public_key, k3$public_key)
  expect_echo(lst, k3_client, "k3")
  expect_echo(lst, relay_client(srv$address, key = k1), "k1 again")

  k4 = tailcat_keygen()
  expect_identical(wait_for(srv$allow_client_async(k4$public_key), 10), srv)
  expect_echo(lst, relay_client(srv$address, key = k4), "k4")
})

test_that("a disallowed client's ping gets no reply and runs out its timeout", {
  # from tailcat_test.go: TestTailcat, pingRejectedForTest
  skip_relay()
  srv = relay_server(allowed_clients = tailcat_keygen()$public_key)
  srv$start()
  cl = relay_client(srv$address)
  started = Sys.time()
  expect_error(cl$ping(timeout = 2), class = "tailcat_timeout")
  expect_gte(as.double(Sys.time() - started, units = "secs"), 1.5)

  srv$allow_client(cl$public_key)
  expect_gte(cl$ping(timeout = 20), 0L)
})

test_that("a client with the right keys but the wrong pre-shared key cannot open a tunnel", {
  # from tailcat_test.go: TestTailcat (wrong-psk-client)
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  address = srv$address
  forged = tamper_psk(address)
  expect_false(identical(forged, address))
  expect_identical(
    tailcat_address_parse(forged)[c("public_key", "disco_public_key", "has_preshared_key")],
    tailcat_address_parse(address)[c("public_key", "disco_public_key", "has_preshared_key")]
  )

  keys = tailcat_keygen()
  srv$allow_client(keys$public_key)
  bad = relay_client(forged, key = keys)
  expect_gte(bad$ping(timeout = 20), 0L)
  expect_error(bad$dial(lst$port, timeout = 3), class = "tailcat_timeout")

  good = tailcat_keygen()
  srv$allow_client(good$public_key)
  expect_echo(lst, relay_client(address, key = good), "right psk")
})
