expect_closed = function(expr, object) {
  cond = tryCatch(expr, error = identity)
  expect_s3_class(cond, "tailcat_closed")
  expect_identical(strsplit(conditionMessage(cond), "\n", fixed = TRUE)[[1]][[1]], paste0("The ", object, " is closed."))
}

test_that("every field and info() fails after close, even after earlier reads", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)
  conns = pair

  expect_true(srv$is_started)
  expect_type(srv$public_key, "character")
  expect_type(unclass(srv$address), "character")
  expect_type(cl$public_key, "character")
  expect_type(lst$port, "integer")
  expect_type(lst$local_address, "character")
  expect_identical(lst$network, "tcp")
  for (conn in conns) {
    expect_type(conn$local_address, "character")
    expect_type(conn$remote_address, "character")
    expect_identical(conn$network, "tcp")
  }

  pair$client$close()
  for (field in c("local_address", "remote_address", "network")) {
    expect_closed(pair$client[[field]], "connection")
  }
  expect_closed(pair$client$info(), "connection")
  expect_type(pair$server$local_address, "character")

  cl$close()
  expect_closed(cl$public_key, "client")
  expect_closed(cl$info(), "client")

  lst$close()
  for (field in c("port", "local_address", "network")) {
    expect_closed(lst[[field]], "listener")
  }
  expect_closed(lst$info(), "listener")
  expect_identical(lst$server, srv)

  srv$close()
  for (field in c("address", "public_key", "is_started")) {
    expect_closed(srv[[field]], "server")
  }
  expect_closed(srv$info(), "server")
  for (field in c("local_address", "remote_address", "network")) {
    expect_closed(pair$server[[field]], "connection")
  }

  for (x in list(srv, cl, lst, pair$client, pair$server)) {
    out = printed(x)
    expect_match(out, "state: +closed")
    expect_false(grepl("public_key|port:", out))
  }
})

test_that("closing the owner closes a listener's and a connection's fields", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)
  expect_type(lst$port, "integer")
  expect_type(pair$client$local_address, "character")

  cl$close()
  expect_closed(pair$client$local_address, "connection")
  expect_closed(pair$client$network, "connection")
  srv$close()
  expect_closed(lst$port, "listener")
  expect_closed(lst$network, "listener")
  expect_match(printed(lst), "network: tcp", fixed = TRUE)
})
