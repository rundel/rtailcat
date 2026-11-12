test_that("a server restarted with the same keys is reachable at its old address", {
  # from cmd/libtailcat/tailcat.h: tc_key_generate (persist both keys); tailcat_test.go: TestAddrSeparateDiscoKey
  skip_relay()
  keys = tailcat_keygen()
  first = relay_server(key = keys)
  first$start()
  old = first$address
  meta = tailcat_address_parse(old)
  expect_false(identical(sub("^[a-z]+:", "", meta$disco_public_key), sub("^[a-z]+:", "", meta$public_key)))
  first$close()

  second = relay_server(key = keys)
  lst = second$listen(0)
  expect_identical(second$public_key, keys$public_key)
  expect_true(second$is_started)
  expect_identical(second$info()$public_key, keys$public_key)
  new = second$address
  new_meta = tailcat_address_parse(new)
  expect_true(new_meta$has_preshared_key)
  expect_identical(new_meta[c("public_key", "disco_public_key", "has_preshared_key")], meta[c("public_key", "disco_public_key", "has_preshared_key")])
  if (identical(new_meta$regions, meta$regions)) {
    expect_identical(new, old)
  }

  cl = relay_client(old)
  pair = connect_pair(lst, cl, lst$port)
  pair$client$write("same address")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "same address")
})

test_that("keeping the private key but not the pre-shared key invalidates old addresses", {
  # from cmd/libtailcat/tailcat.h: tc_key_generate; tailcat_test.go: TestAddrPresharedKey
  skip_relay()
  keys = tailcat_keygen()
  first = relay_server(key = keys)
  first$start()
  old = first$address
  first$close()

  rotated = relay_server(key = keys$private_key, preshared_key = tailcat_keygen()$preshared_key)
  lst = rotated$listen(0)
  expect_false(identical(rotated$address, old))
  expect_identical(tailcat_address_parse(rotated$address)$public_key, keys$public_key)

  stale = relay_client(old)
  expect_error(stale$dial(lst$port, timeout = 3), class = "tailcat_timeout")
  fresh = relay_client(rotated$address)
  pair = connect_pair(lst, fresh, lst$port)
  pair$client$write("rotated")
  expect_identical(rawToChar(pair$server$read(timeout = 20)), "rotated")
})
