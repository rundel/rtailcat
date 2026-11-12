offline_address = function() {
  tc_address(list(p = as.raw(c(rep(0, 31), 1)), k = as.raw(1:32), q = as.raw(1:32), i = 10))
}

test_that("a closed client rejects every operation with tailcat_closed", {
  # from cmd/libtailcat/testdata/smoke.c (closed-handle checks)
  cl = TailcatClient$new(offline_address())
  expect_false(cl$is_closed)
  expect_invisible(cl$close())
  expect_identical(cl$close(), cl)
  expect_true(cl$is_closed)
  expect_error(cl$dial(80, timeout = 5), class = "tailcat_closed")
  expect_error(cl$ping(timeout = 5), class = "tailcat_closed")
  expect_error(cl$disco_ping(timeout = 5), class = "tailcat_closed")
  expect_error(cl$info(), class = "tailcat_closed")
  expect_error(cl$drain(), class = "tailcat_closed")
  expect_error(wait_for(cl$ping_async(timeout = 5), 10), class = "tailcat_closed")
  expect_error(wait_for(cl$dial_async(80, timeout = 5), 10), class = "tailcat_closed")
  expect_match(printed(cl), "closed", fixed = TRUE)
})

test_that("an unused client reports its public key and drains without network access", {
  # from internal/capi/e2e_test.go: TestE2EClientPingAndInfo (drain before start, info)
  keys = tailcat_keygen()
  cl = TailcatClient$new(offline_address(), key = keys$private_key)
  on.exit(cl$close())
  expect_identical(cl$info()$public_key, keys$public_key)
  expect_identical(cl$public_key, keys$public_key)
  expect_invisible(cl$drain(timeout = 1))
  expect_identical(wait_for(cl$drain_async(timeout = 1), 5), cl)

  generated = TailcatClient$new(offline_address())
  on.exit(generated$close(), add = TRUE)
  expect_match(generated$public_key, "^nodekey:[0-9a-f]{64}$")
  expect_identical(generated$info()$public_key, generated$public_key)
  expect_false(identical(generated$public_key, keys$public_key))
})

test_that("a zero timeout polls and fails at once with tailcat_timeout when nothing is ready", {
  # from cmd/libtailcat/tailcat.h: tc_token_new (0 expires immediately), internal/capi/token_test.go; rtailcat polls with a few milliseconds instead
  map_url = silent_map_url()
  cl = TailcatClient$new(offline_address(), derp_map_url = map_url)
  on.exit(cl$close())
  started = Sys.time()
  expect_error(cl$dial(80, timeout = 0), class = "tailcat_timeout")
  expect_error(cl$ping(timeout = 0), class = "tailcat_timeout")
  expect_error(cl$disco_ping(timeout = 0), class = "tailcat_timeout")
  expect_error(wait_for(cl$dial_async(80, timeout = 0), 5), class = "tailcat_timeout")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)
})

test_that("configuration errors never echo the secret that was rejected", {
  # from internal/capi/api_test.go: TestInvalidConfigurationDoesNotEchoSecrets
  secret = "privkey:supersecretvalue0123456789"
  secret_address = "tcsupersecretaddressvalue0123456789"
  messages = c(
    conditionMessage(tryCatch(TailcatServer$new(key = secret), error = identity)),
    conditionMessage(tryCatch(TailcatServer$new(preshared_key = secret), error = identity)),
    conditionMessage(tryCatch(TailcatServer$new(allowed_clients = secret), error = identity)),
    conditionMessage(tryCatch(TailcatClient$new(secret_address), error = identity)),
    conditionMessage(tryCatch(TailcatClient$new(offline_address(), key = secret), error = identity)),
    conditionMessage(tryCatch(tailcat_address_parse(secret_address), error = identity)),
    conditionMessage(tryCatch(tailcat_address_resolve(secret_address, timeout = 1), error = identity))
  )
  for (msg in messages) {
    expect_false(grepl("supersecret", msg, fixed = TRUE))
  }
  expect_error(TailcatServer$new(key = secret), "invalid private key", class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(preshared_key = secret), "invalid pre-shared key", class = "tailcat_invalid_argument")
  expect_error(TailcatClient$new(offline_address(), key = secret), class = "tailcat_invalid_argument")
})

test_that("an unstarted server accepts allowlist additions and a zero UDP idle timeout", {
  # from internal/capi/api_test.go: TestAllowClientKeepsAllowlistSemantics (before startup); tailcat_test.go: TestUDPIdleTimeoutDefault
  srv = TailcatServer$new(udp_idle_timeout = 0)
  on.exit(srv$close())
  expect_identical(srv$allow_client(tailcat_keygen()$public_key, timeout = 5), srv)
  expect_identical(wait_for(srv$allow_client_async(tailcat_keygen()$public_key, timeout = 5), 10), srv)
  expect_identical(srv$public_key, NA_character_)

  listed = TailcatServer$new(allowed_clients = c(tailcat_keygen()$public_key, tailcat_keygen()$public_key))
  on.exit(listed$close(), add = TRUE)
  expect_identical(listed$allow_client(tailcat_keygen()$public_key), listed)
})
