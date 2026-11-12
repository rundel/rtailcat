expect_format_matches_print = function(x) {
  lines = format(x)
  expect_type(lines, "character")
  expect_identical(lines, x$format())
  expect_identical(utils::capture.output(print(x)), lines)
  utils::capture.output(visible <- withVisible(print(x)))
  expect_identical(visible, list(value = x, visible = FALSE))
  invisible(lines)
}

test_that("format() of servers and clients matches print() when never started, closed, and restored", {
  map_url = silent_map_url()
  keys = tailcat_keygen()
  srv = TailcatServer$new(key = keys, derp_map_url = map_url)
  on.exit(srv$close(), add = TRUE)
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)), key = keys)
  on.exit(cl$close(), add = TRUE)

  out = expect_format_matches_print(srv)
  expect_identical(out[[1]], "<TailcatServer>")
  expect_true(any(grepl("not started", out, fixed = TRUE)))
  out = expect_format_matches_print(cl)
  expect_true(any(grepl(keys$public_key, out, fixed = TRUE)))
  for (out in list(format(srv), format(cl))) {
    expect_true(any(grepl("<redacted>", out, fixed = TRUE)))
    expect_false(any(grepl(keys$private_key, out, fixed = TRUE)))
    expect_false(any(grepl(keys$preshared_key, out, fixed = TRUE)))
  }

  path = withr::local_tempfile(fileext = ".rds")
  saveRDS(list(srv = srv, cl = cl), path)
  restored = readRDS(path)
  for (x in restored) {
    out = expect_format_matches_print(x)
    expect_match(out[[2]], "closed (restored from a saved session)", fixed = TRUE)
  }

  srv$close()
  cl$close()
  for (x in list(srv, cl)) {
    out = expect_format_matches_print(x)
    expect_length(out, 2)
    expect_match(out[[2]], "state: +closed$")
  }
})

test_that("format() of listeners and connections matches print(), and shows endpoints only while open", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  out = expect_format_matches_print(lst)
  expect_true(any(grepl(paste0("port: +", lst$port, "$"), out)))

  sc = pair$server
  cc = pair$client
  out = expect_format_matches_print(sc)
  expect_true(paste0("  local:   ", sc$local_address) %in% out)
  expect_true(paste0("  remote:  ", sc$remote_address) %in% out)
  expect_true("  network: tcp" %in% out)
  out = expect_format_matches_print(cc)
  expect_true(paste0("  local:   ", cc$local_address) %in% out)
  expect_true(paste0("  remote:  ", cc$remote_address) %in% out)
  expect_false(any(grepl(as.character(srv$address), c(format(sc), format(cc), format(lst)), fixed = TRUE)))

  cc$close()
  out = expect_format_matches_print(cc)
  expect_match(out[[2]], "state: +closed$")
  expect_false(any(grepl("local:|remote:", out)))

  srv$close()
  for (x in list(lst, sc)) {
    out = expect_format_matches_print(x)
    expect_match(out[[2]], "state: +closed$")
    expect_false(any(grepl("local:|remote:|port:", out)))
  }
})

test_that("format() leaves the endpoints out once close_write() has succeeded", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  expect_true(any(grepl("local:", format(pair$client), fixed = TRUE)))
  wait_for(pair$client$close_write_async(), 20)
  out = format(pair$client)
  expect_match(out[[2]], "state: +open$")
  expect_false(any(grepl("local:|remote:", out)))
  expect_true(any(grepl("local:", format(pair$server), fixed = TRUE)))
  expect_null(pair$server$read(timeout = 20))
  pair$server$close_write()
  expect_false(any(grepl("local:|remote:", format(pair$server))))
})

test_that("printing a connection after both sides half-close prints no Go stack trace", {
  skip_relay()
  skip_if_not_installed("processx")
  child = child_r(c(
    "srv = TailcatServer$new(region = region)",
    "lst = srv$listen(0)",
    "cl = TailcatClient$new(srv$address, derp_map_url = derp_map_url)",
    "pending = lst$accept_async(timeout = 30)",
    "cc = cl$dial(lst$port, timeout = 30)",
    "sc = NULL",
    "promises::then(pending, function(conn) sc <<- conn)",
    "deadline = Sys.time() + 30",
    "while (is.null(sc) && Sys.time() < deadline) later::run_now(0.05)",
    "cc$close_write()",
    "stopifnot(is.null(sc$read(timeout = 20)))",
    "sc$close_write()",
    "stopifnot(is.null(cc$read(timeout = 20)))",
    "Sys.sleep(1)",
    "print(sc)",
    "print(cc)",
    "cat('DONE\\n')",
    "srv$close()",
    "cl$close()"
  ))
  out = child_finish(child, timeout = 90)
  expect_true("DONE" %in% out$stdout)
  expect_true(any(grepl("state: +open", out$stdout)))
  expect_false(any(grepl("local:|remote:", out$stdout)))
  expect_false(any(grepl("libtailcat: internal failure|panic|goroutine", out$stderr)))
})

test_that("connections give their owner through $client or $server, also after close", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  expect_identical(pair$client$client, cl)
  expect_null(pair$client$server)
  expect_identical(pair$server$server, srv)
  expect_null(pair$server$client)
  expect_error(pair$client$client <- NULL, class = "tailcat_invalid_argument")
  expect_error(pair$server$server <- NULL, class = "tailcat_invalid_argument")

  pair$client$close()
  srv$close()
  expect_identical(pair$client$client, cl)
  expect_identical(pair$server$server, srv)
  expect_null(pair$server$client)
})
