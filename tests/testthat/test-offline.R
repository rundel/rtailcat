test_that("build info reports ABI version 1", {
  info = tailcat_build_info()
  expect_identical(info$abi_version, 1L)
  expect_type(info$go_version, "character")
  expect_type(info$tailcat_version, "character")
  expect_named(info, c("abi_version", "go_version", "tailcat_version", "raw"))
  expect_type(info$raw, "list")
  expect_identical(info$raw$GoVersion, info$go_version)
})

test_that("keygen returns distinct keys and redacts secrets when printed", {
  k1 = tailcat_keygen()
  k2 = tailcat_keygen()
  expect_s3_class(k1, "tailcat_keys")
  expect_named(k1, c("private_key", "public_key", "preshared_key"))
  expect_true(all(vapply(k1, function(x) is.character(x) && nzchar(x), logical(1))))
  expect_false(identical(k1$private_key, k2$private_key))
  expect_match(k1$public_key, "^nodekey:")

  out = printed(k1)
  expect_match(out, k1$public_key, fixed = TRUE)
  expect_match(out, "<redacted>", fixed = TRUE)
  expect_false(grepl(k1$private_key, out, fixed = TRUE))
  expect_false(grepl(k1$preshared_key, out, fixed = TRUE))
  expect_false(grepl(sub("^[a-z]+:", "", k1$private_key), out, fixed = TRUE))
  expect_false(grepl(sub("^[a-z]+:", "", k1$preshared_key), out, fixed = TRUE))
})

test_that("address parsing rejects bad input", {
  expect_error(tailcat_address_parse("not an address"), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_parse(""), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_parse(1), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_parse(c("a", "b")), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_resolve("not an address", timeout = 5), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_resolve("x", timeout = -1), class = "tailcat_invalid_argument")
  expect_error(
    wait_for(tailcat_address_resolve_async("not an address", timeout = 5), 10),
    class = "tailcat_invalid_argument"
  )
})

test_that("tailcat errors map to condition classes", {
  kinds = c("invalid_argument", "closed", "timeout", "canceled", "failure")
  for (status in 1:5) {
    err = structure(list(status = status, message = "boom", bytes = 7L), class = "rtc_error")
    cond = rtailcat:::rtc_condition(err)
    expect_s3_class(cond, c(paste0("tailcat_", kinds[[status]]), "tailcat_error"))
    expect_identical(cond$status, status)
    expect_identical(cond$bytes, 7L)
    expect_match(conditionMessage(cond), "boom")
    expect_error(rtailcat:::rtc_value(err), class = paste0("tailcat_", kinds[[status]]))
  }
  odd = structure(list(status = 99L, message = "", bytes = 0L), class = "rtc_error")
  expect_s3_class(rtailcat:::rtc_condition(odd), "tailcat_failure")
  expect_identical(rtailcat:::rtc_value(42), 42)
})

test_that("rtc_promise resolves values and rejects tailcat errors", {
  ok = rtailcat:::rtc_promise(function(cb) cb("value"), toupper)
  expect_identical(wait_for(ok, 5), "VALUE")

  err = structure(list(status = 3L, message = "late", bytes = 2L), class = "rtc_error")
  bad = rtailcat:::rtc_promise(function(cb) cb(err))
  cond = tryCatch(wait_for(bad, 5), error = function(e) e)
  expect_s3_class(cond, "tailcat_timeout")
  expect_identical(cond$bytes, 2L)

  broken = rtailcat:::rtc_promise(function(cb) cb("x"), function(x) stop("transform failed"))
  expect_error(wait_for(broken, 5), "transform failed")
})

test_that("server configuration is validated", {
  expect_error(TailcatServer$new(key = "nope"), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(preshared_key = "nope"), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(allowed_clients = "nope"), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(allowed_clients = 1), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(udp_idle_timeout = -1), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(udp_idle_timeout = Inf), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(region_id = -1), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(region_id = 1.5), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(region = 1), class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(region = "{not json"), class = "tailcat_invalid_argument")

  keys = tailcat_keygen()
  srv = TailcatServer$new(
    key = keys,
    region_id = 1,
    region = list(RegionID = 1L, RegionCode = "test", Nodes = list(list(Name = "n", RegionID = 1L, HostName = "localhost"))),
    allowed_clients = tailcat_keygen()$public_key,
    udp_idle_timeout = 10
  )
  on.exit(srv$close())
  expect_identical(srv$public_key, NA_character_)
  expect_false(srv$is_started)
  expect_false(srv$is_closed)
})

test_that("client configuration is validated", {
  expect_error(TailcatClient$new("not an address"), class = "tailcat_invalid_argument")
  expect_error(TailcatClient$new(NA_character_), class = "tailcat_invalid_argument")
  expect_error(TailcatClient$new(), "address")
})

test_that("listeners and connections cannot be created directly", {
  expect_error(TailcatListener$new(NULL, NULL, 1L), class = "tailcat_invalid_argument")
  expect_error(TailcatConnection$new(NULL, NULL, 1L), class = "tailcat_invalid_argument")
})

test_that("an unstarted server reports its state without network access", {
  map_url = silent_map_url()
  srv = TailcatServer$new(derp_map_url = map_url)
  on.exit(srv$close())
  expect_identical(srv$public_key, NA_character_)
  expect_false(srv$is_started)
  expect_error(srv$address, class = "tailcat_invalid_argument")
  expect_error(srv$info(), class = "tailcat_invalid_argument")
  expect_invisible(srv$drain())
  expect_error(srv$start(timeout = 0), class = "tailcat_timeout")
  expect_error(wait_for(srv$start_async(timeout = 0), 10), class = "tailcat_timeout")

  out = printed(srv)
  expect_match(out, "not started", fixed = TRUE)
  expect_match(out, "<redacted>", fixed = TRUE)
})

test_that("closed handles raise tailcat_closed and close is idempotent", {
  keys = tailcat_keygen()
  srv = TailcatServer$new(key = keys)
  expect_false(srv$is_closed)
  expect_identical(withVisible(srv$close())$visible, FALSE)
  expect_identical(srv$close(), srv)
  expect_true(srv$is_closed)

  expect_error(srv$start(), class = "tailcat_closed")
  expect_error(srv$listen(80), class = "tailcat_closed")
  expect_error(srv$info(), class = "tailcat_closed")
  expect_error(srv$drain(), class = "tailcat_closed")
  expect_error(srv$allow_client(keys$public_key), class = "tailcat_closed")
  expect_error(wait_for(srv$start_async(), 10), class = "tailcat_closed")
  expect_error(wait_for(srv$listen_async(80), 10), class = "tailcat_closed")

  expect_error(srv$public_key, class = "tailcat_closed")
  expect_error(srv$is_started, class = "tailcat_closed")
  expect_error(srv$address, class = "tailcat_closed")

  out = printed(srv)
  expect_match(out, "closed", fixed = TRUE)
  expect_false(grepl("public_key", out, fixed = TRUE))
  expect_false(grepl(keys$private_key, out, fixed = TRUE))
  expect_false(grepl(keys$preshared_key, out, fixed = TRUE))
})

test_that("arguments are checked before any work starts", {
  srv = TailcatServer$new()
  on.exit(srv$close())
  expect_error(srv$start(timeout = -1), class = "tailcat_invalid_argument")
  expect_error(srv$start(timeout = NA), class = "tailcat_invalid_argument")
  expect_error(srv$start(timeout = "1"), class = "tailcat_invalid_argument")
  expect_error(srv$listen(port = 70000), class = "tailcat_invalid_argument")
  expect_error(srv$listen(port = 1.5), class = "tailcat_invalid_argument")
  expect_error(srv$listen(network = "sctp"), class = "tailcat_invalid_argument")
  expect_error(srv$allow_client(NA_character_), class = "tailcat_invalid_argument")
  expect_error(srv$allow_client("nope"), class = "tailcat_invalid_argument")
  expect_error({srv$address = "x"}, class = "tailcat_invalid_argument")
})

test_that("payloads are converted to raw", {
  expect_identical(rtailcat:::as_payload(as.raw(1:3)), as.raw(1:3))
  expect_identical(rtailcat:::as_payload(c("ab", "c")), charToRaw("abc"))
  expect_identical(rtailcat:::as_payload("é"), as.raw(c(0xc3, 0xa9)))
  expect_identical(rtailcat:::as_payload(iconv("é", "UTF-8", "latin1")), as.raw(c(0xc3, 0xa9)))
  expect_identical(rtailcat:::as_payload(character()), raw(0))
  expect_error(rtailcat:::as_payload(NA_character_), class = "tailcat_invalid_argument")
  expect_error(rtailcat:::as_payload(1:3), class = "tailcat_invalid_argument")
})

test_that("the native layer rejects wrong handle kinds and argument types", {
  srv = TailcatServer$new()
  on.exit(srv$close())
  h = srv$.__enclos_env__$private$handle
  expect_s3_class(h, c("rtc_server", "rtc_handle"))
  expect_error(rtailcat:::rtc_listener_accept(h, 1, NULL), "rtc_server")
  expect_error(rtailcat:::rtc_client_ping(h, 1, NULL), "rtc_server")
  expect_error(rtailcat:::rtc_close("x"), "handle")
  expect_error(rtailcat:::rtc_server_start(h, 1, "not a function"), "callback")
})

test_that("the package refuses to run in a forked child", {
  skip_on_os("windows")
  res = parallel::mcparallel(tryCatch(tailcat_keygen(), error = function(e) conditionMessage(e)))
  out = parallel::mccollect(res)[[1]]
  expect_type(out, "character")
  expect_match(out, "forked child", fixed = TRUE)
})

test_that("callbacks passed to the native layer never let errors escape", {
  seen = NULL
  cb = rtailcat:::rtc_callback(function(x) stop("body failed"), on_error = function(e) seen <<- conditionMessage(e))
  expect_no_error(cb(1))
  expect_identical(seen, "body failed")
  cb2 = rtailcat:::rtc_callback(function(x) stop("body"), on_error = function(e) stop("handler"))
  expect_no_error(cb2(1))
  expect_null(cb2(1))
})

test_that("a server takes its keys from a tailcat_keys object, with preshared_key overriding", {
  keys = tailcat_keygen()
  srv = TailcatServer$new(key = keys)
  on.exit(srv$close())
  expect_false(srv$is_closed)
  other = tailcat_keygen()
  mixed = TailcatServer$new(key = keys, preshared_key = other$preshared_key)
  on.exit(mixed$close(), add = TRUE)
  expect_false(mixed$is_closed)
  expect_error(TailcatServer$new(keys = keys), "unused argument")

  for (bad in list(
    structure(list(), class = "tailcat_keys"),
    structure(list(private_key = "x"), class = "tailcat_keys"),
    structure(list(private_key = keys$private_key, public_key = keys$public_key, preshared_key = NA_character_), class = "tailcat_keys"),
    structure("privkey:x", class = "tailcat_keys")
  )) {
    expect_error(TailcatServer$new(key = bad), "tailcat_keys", class = "tailcat_invalid_argument")
    expect_error(TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)), key = bad), "tailcat_keys", class = "tailcat_invalid_argument")
  }
})

test_that("choice arguments take the default or exactly one value, for network and as alike", {
  expect_identical(rtailcat:::network_code(c("tcp", "udp")), 1L)
  expect_identical(rtailcat:::network_code("udp"), 2L)
  expect_identical(rtailcat:::check_as(c("raw", "text")), "raw")
  expect_identical(rtailcat:::check_as("text"), "text")
  for (bad in list("TCP", "tc", c("udp", "tcp"), NA_character_, "", 1, character())) {
    expect_error(rtailcat:::network_code(bad), "`network` must be one of", class = "tailcat_invalid_argument")
  }
  for (bad in list("RAW", "t", c("text", "raw"), NA_character_, 1)) {
    expect_error(rtailcat:::check_as(bad), "`as` must be one of", class = "tailcat_invalid_argument")
  }
})
