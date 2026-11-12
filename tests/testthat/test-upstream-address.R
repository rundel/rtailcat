test_key = function() {
  key = raw(32)
  key[c(2, 3, 32)] = as.raw(c(1, 2, 31))
  key
}
test_disco = as.raw(1:32)
test_psk = as.raw(101:132)

test_that("tailcat_address_parse() decodes upstream's reference addresses", {
  # from tailcat_test.go: TestAddr (just_key, region_id)
  just_key = "tcoWFwWCAAAQIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHw"
  with_region = "tcomFwWCAAAQIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH2FpCg"
  expect_identical(tc_address(list(p = test_key())), just_key)
  expect_identical(tc_address(list(p = test_key(), i = 10)), with_region)

  hex = paste(as.character(test_key()), collapse = "")
  expect_identical(nchar(hex), 64L)
  meta = tailcat_address_parse(just_key)
  expect_identical(meta$public_key, paste0("nodekey:", hex))
  expect_identical(meta$region_id, 0L)
  expect_false(meta$has_preshared_key)
  expect_null(meta$regions)
  expect_identical(tailcat_address_parse(with_region)$region_id, 10L)
})

test_that("embedded relay regions get upstream's implicit IDs, codes and node names", {
  # from tailcat_test.go: TestAddr (key_with_full_custom_region)
  addr = tc_address(list(
    p = test_key(),
    k = test_disco,
    r = list(
      list(N = list(
        list(h = "my-derp.custom.example", `4` = "400.400.400.400"),
        list(h = "my-derp2.custom.example", `4` = "400.400.400.400")
      )),
      list(i = 7, c = "sea", N = list(list(n = "7a", h = "sea.example", `6` = "none", s = -1, d = 8443, t = "cert.example", x = TRUE)))
    )
  ))
  regions = tailcat_address_parse(addr)$regions
  expect_length(regions, 2)

  first = regions[[1]]
  expect_identical(first$region_id, 1L)
  expect_identical(first$region_code, "1")
  expect_identical(vapply(first$nodes, function(n) n$name, ""), c("my-derp.custom.example", "my-derp2.custom.example"))
  expect_identical(vapply(first$nodes, function(n) n$region_id, 0L), c(1L, 1L))
  expect_identical(first$nodes[[1]]$ipv4, "400.400.400.400")

  second = regions[[2]]
  expect_identical(second$region_id, 7L)
  expect_identical(second$region_code, "sea")
  node = second$nodes[[1]]
  expect_identical(node$name, "7a")
  expect_identical(node$host_name, "sea.example")
  expect_identical(node$ipv6, "none")
  expect_identical(node$stun_port, -1L)
  expect_identical(node$relay_port, 8443L)
  expect_identical(node$cert_name, "cert.example")
  expect_true(node$insecure_for_tests)
  names_seen = unique(c(names(first), names(second), unlist(lapply(c(first$nodes, second$nodes), names))))
  expect_true(all(grepl("^[a-z0-9_]+$", names_seen)))
})

test_that("has_preshared_key reflects the address and the key itself is never returned", {
  # from tailcat_test.go: TestAddrPresharedKey
  with_psk = tc_address(list(p = test_key(), k = test_disco, q = test_psk, i = 10))
  without_psk = tc_address(list(p = test_key(), k = test_disco, i = 10))
  meta = tailcat_address_parse(with_psk)
  expect_true(meta$has_preshared_key)
  expect_false(tailcat_address_parse(without_psk)$has_preshared_key)
  expect_lt(nchar(without_psk), nchar(with_psk))
  expect_setequal(names(meta), c("public_key", "disco_public_key", "has_preshared_key", "region_id", "regions"))
  flat = paste(unlist(meta), collapse = " ")
  expect_false(grepl(paste(as.character(test_psk), collapse = ""), flat, fixed = TRUE))
  expect_identical(meta$disco_public_key, paste0("discokey:", paste(as.character(test_disco), collapse = "")))
})

test_that("malformed key lengths are rejected as invalid arguments", {
  # from tailcat_test.go: TestParseAddrMalformedPublicKey, TestParseAddrMalformedDiscoPublicKey, TestParseAddrMalformedPresharedKey
  for (len in c(31, 33)) {
    bad = list(
      list(p = raw(len)),
      list(p = test_key(), k = as.raw(seq_len(len))),
      list(p = test_key(), k = test_disco, q = as.raw(seq_len(len)))
    )
    for (fields in bad) {
      addr = tc_address(fields)
      expect_error(tailcat_address_parse(addr), class = "tailcat_invalid_argument")
      expect_error(TailcatClient$new(addr), class = "tailcat_invalid_argument")
    }
  }
})

test_that("null regions or nodes are rejected rather than crashing", {
  # from tailcat_test.go: TestParseAddrNullInArrays
  null_region = tc_address(list(p = test_key(), k = test_disco, r = list(NULL)))
  null_node = tc_address(list(p = test_key(), k = test_disco, r = list(list(i = 1, N = list(NULL)))))
  for (addr in c(null_region, null_node)) {
    expect_error(tailcat_address_parse(addr), class = "tailcat_invalid_argument")
    expect_error(tailcat_address_resolve(addr, timeout = 5), class = "tailcat_invalid_argument")
    expect_error(TailcatClient$new(addr), class = "tailcat_invalid_argument")
  }
  expect_error(tailcat_address_parse(substring(null_region, 3)), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_parse("tc!!!"), class = "tailcat_invalid_argument")
})

test_that("TailcatClient$new() rejects legacy addresses without a disco key", {
  # from tailcat_test.go: TestClientRejectsLegacyAddr
  legacy = tc_address(list(p = test_key(), i = 10))
  expect_no_error(tailcat_address_parse(legacy))
  expect_error(TailcatClient$new(legacy), class = "tailcat_invalid_argument")
})

test_that("TailcatClient$new() accepts an address without a pre-shared key", {
  # from tailcat_test.go: TestClientAcceptsAddrWithoutPresharedKey
  addr = tc_address(list(p = test_key(), k = test_disco, i = 10))
  cl = TailcatClient$new(addr)
  on.exit(cl$close())
  expect_false(cl$is_closed)
  expect_match(cl$public_key, "^nodekey:")
})

test_that("resolving an address that already embeds a relay region is a local no-op", {
  # from cmd/libtailcat/tailcat.h: tc_address_resolve contract (no upstream test)
  addr = tc_address(list(p = test_key(), k = test_disco, q = test_psk, r = list(list(N = list(list(h = "relay.invalid"))))))
  resolved = tailcat_address_resolve(addr, derp_map_url = "http://127.0.0.1:9/unreachable", timeout = 5)
  expect_s3_class(resolved, "tailcat_secret")
  expect_identical(unclass(resolved), addr)
  resolved = wait_for(tailcat_address_resolve_async(addr, timeout = 5), 10)
  expect_s3_class(resolved, "tailcat_secret")
  expect_identical(as.character(resolved), addr)
})
