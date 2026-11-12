offline_client = function(env = parent.frame()) {
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)))
  withr::defer(cl$close(), envir = env)
  cl
}

test_that("region_id beyond the integer range is rejected clearly", {
  expect_error(TailcatServer$new(region_id = 3e9), "region_id", class = "tailcat_invalid_argument")
  expect_error(TailcatServer$new(region_id = 2^31), "region_id", class = "tailcat_invalid_argument")
  srv = TailcatServer$new(region_id = .Machine$integer.max)
  srv$close()
})

test_that("dial checks port and network before any work starts", {
  cl = offline_client()
  for (port in list(0, 65536, NA, NA_integer_, -1, 1.5, "80", c(80, 81))) {
    expect_error(cl$dial(port), class = "tailcat_invalid_argument")
    expect_error(cl$dial_async(port), class = "tailcat_invalid_argument")
  }
  for (network in list(NA_character_, "", "sctp", 1, character())) {
    expect_error(cl$dial(80, network = network), class = "tailcat_invalid_argument")
  }
  expect_error(cl$dial(80, timeout = -1), class = "tailcat_invalid_argument")
})

test_that("addresses are accepted with surrounding whitespace", {
  addr = tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10))
  meta = tailcat_address_parse(addr)
  expect_identical(tailcat_address_parse(paste0("  ", addr, "\n")), meta)
  expect_identical(tailcat_address_parse(rtailcat:::new_secret(addr)), meta)
  cl = TailcatClient$new(paste0(addr, "\r\n"))
  expect_false(cl$is_closed)
  cl$close()
  resolved = tc_address(list(p = as.raw(1:32), k = as.raw(33:64), r = list(list(N = list(list(h = "relay.invalid"))))))
  expect_identical(unclass(tailcat_address_resolve(paste0("\t", resolved, "\n"), timeout = 5)), resolved)
  expect_error(TailcatClient$new("   "), class = "tailcat_invalid_argument")
  expect_error(tailcat_address_parse("\n"), class = "tailcat_invalid_argument")
})

test_that("read-only fields of servers and clients refuse assignment", {
  srv = TailcatServer$new()
  on.exit(srv$close())
  cl = offline_client()
  for (field in c("address", "public_key", "is_started", "is_closed")) {
    expect_error({srv[[field]] = "x"}, "read-only", class = "tailcat_invalid_argument")
  }
  for (field in c("public_key", "is_closed")) {
    expect_error({cl[[field]] = "x"}, "read-only", class = "tailcat_invalid_argument")
  }
})

test_that("rarely used async methods resolve like their blocking versions", {
  keys = tailcat_keygen()
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)), key = keys)
  on.exit(cl$close())
  expect_identical(wait_for(cl$info_async(), 10), cl$info())
  expect_identical(wait_for(cl$info_async(), 10)$public_key, keys$public_key)

  srv = TailcatServer$new()
  on.exit(srv$close(), add = TRUE)
  expect_identical(wait_for(srv$drain_async(timeout = 1), 10), srv)
  expect_identical(wait_for(srv$drain_async(timeout = Inf), 10), srv)
  expect_invisible(srv$drain(timeout = Inf))
  srv$close()
  expect_error(wait_for(srv$drain_async(), 10), class = "tailcat_closed")
})

test_that("objects restored from a saved session are closed and say why", {
  keys = tailcat_keygen()
  srv = TailcatServer$new(key = keys)
  on.exit(srv$close())
  cl = offline_client()
  path = withr::local_tempfile(fileext = ".rds")
  saveRDS(list(srv = srv, cl = cl), path)
  restored = readRDS(path)
  rs = restored$srv
  rc = restored$cl

  expect_true(rs$is_closed)
  expect_true(rc$is_closed)
  expect_error(rs$start(timeout = 1), class = "tailcat_closed")
  expect_error(rs$info(), class = "tailcat_closed")
  expect_error(wait_for(rs$listen_async(0), 10), class = "tailcat_closed")
  expect_error(rc$ping(timeout = 1), class = "tailcat_closed")
  expect_error(wait_for(rc$dial_async(80), 10), class = "tailcat_closed")
  expect_identical(rs$close(), rs)
  expect_identical(rc$close(), rc)
  expect_match(printed(rs), "closed (restored from a saved session)", fixed = TRUE)
  expect_match(printed(rc), "closed (restored from a saved session)", fixed = TRUE)
  expect_error(rs$public_key, class = "tailcat_closed")
  expect_error(rc$public_key, class = "tailcat_closed")
  for (cond in list(tryCatch(rs$info(), error = identity), tryCatch(rc$public_key, error = identity), tryCatch(wait_for(rc$ping_async(), 10), error = identity))) {
    expect_s3_class(cond, "tailcat_closed")
    expect_match(conditionMessage(cond), "restored from a saved session")
    expect_match(conditionMessage(cond), "do not survive serialization")
  }
  expect_false(srv$is_closed)
  expect_false(cl$is_closed)
})

test_that("read arguments, listener and connection fields, and blocking accept work at their boundaries", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pending = cl$dial_async(lst$port, timeout = 30)
  sc = lst$accept(timeout = 30)
  expect_s3_class(sc, "TailcatConnection")
  cc = wait_for(pending, 30)
  cc$write("blocking accept")
  expect_identical(sc$read(timeout = 20, as = "text"), "blocking accept")
  expect_match(printed(sc), "server (accepted)", fixed = TRUE)
  expect_match(printed(cc), "client (dialed)", fixed = TRUE)

  for (n in list(-1, 1.5, NA, NA_real_, 2^31, "1", c(1, 2), Inf)) {
    expect_error(sc$read(n = n), class = "tailcat_invalid_argument")
    expect_error(sc$read_async(n = n), class = "tailcat_invalid_argument")
  }
  cc$write("x")
  expect_identical(sc$read(n = 2^31 - 1, timeout = 20), charToRaw("x"))

  for (field in c("port", "local_address", "network", "server", "is_closed")) {
    expect_error({lst[[field]] = 1}, "read-only", class = "tailcat_invalid_argument")
  }
  for (field in c("local_address", "remote_address", "network", "is_closed")) {
    expect_error({sc[[field]] = 1}, "read-only", class = "tailcat_invalid_argument")
  }
  expect_identical(lst$server, srv)

  info = wait_for(lst$info_async(), 10)
  expect_identical(info, lst$info())
  expect_identical(info$network, "tcp")
  expect_identical(rtailcat:::endpoint_port(info$local_address), lst$port)
})

test_that("an interrupt ends a blocking accept and leaves the listener usable", {
  skip_relay()
  skip_on_os("windows")
  skip_if_not_installed("processx")
  child = child_r(c(
    "srv = TailcatServer$new(region = region)",
    "lst = srv$listen(0)",
    "cat('READY\\\\n')",
    "started = Sys.time()",
    "res = tryCatch({ lst$accept(); 'accepted' }, interrupt = function(e) 'interrupted')",
    "cat('ACCEPT', res, round(as.double(Sys.time() - started, units = 'secs'), 1), '\\\\n')",
    "res = tryCatch({ lst$accept(timeout = 0.2); 'accepted' }, tailcat_timeout = function(e) 'timeout')",
    "cat('AFTER', res, '\\\\n')",
    "srv$close()"
  ))
  seen = wait_child_line(child, "^READY", timeout = 60)
  expect_true(any(grepl("^READY", seen)))
  Sys.sleep(0.5)
  child$interrupt()
  out = child_finish(child, timeout = 30)
  lines = c(seen, out$stdout)
  accept = grep("^ACCEPT", lines, value = TRUE)
  expect_length(accept, 1)
  expect_match(accept, "^ACCEPT interrupted")
  expect_lt(as.double(sub("^ACCEPT interrupted ", "", accept)), 10)
  expect_true(any(grepl("^AFTER timeout", lines)))
})
