offline_address = function() {
  tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10))
}

in_flight = function() {
  rtc_operations_in_flight()
}

test_that("max_operations_option() validates the option", {
  withr::local_options(rtailcat.max_operations = NULL)
  expect_identical(max_operations_option(), 1024)
  for (value in list(1, 1L, 50, 2^40, Inf)) {
    withr::local_options(rtailcat.max_operations = value)
    expect_identical(max_operations_option(), as.double(value))
  }
  for (value in list(0, -1, 1.5, NA, NA_real_, NaN, -Inf, "10", TRUE, c(1, 2), numeric(0), list(10))) {
    withr::local_options(rtailcat.max_operations = value)
    expect_identical(max_operations_option(), NA_real_)
  }
})

test_that("an invalid rtailcat.max_operations makes operations fail with tailcat_failure", {
  map_url = silent_map_url()
  base = in_flight()
  withr::local_options(rtailcat.max_operations = 0)
  cond = tryCatch(tailcat_address_resolve(offline_address(), derp_map_url = map_url, timeout = 0), error = identity)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$status, 5L)
  expect_match(conditionMessage(cond), "rtailcat.max_operations option must be a single positive whole number or Inf", fixed = TRUE)
  expect_error(wait_for(tailcat_address_resolve_async(offline_address(), derp_map_url = map_url, timeout = 0), 10), "rtailcat.max_operations", class = "tailcat_failure")
  expect_identical(in_flight(), base)

  withr::local_options(rtailcat.max_operations = Inf)
  expect_error(tailcat_address_resolve(offline_address(), derp_map_url = map_url, timeout = 0), class = "tailcat_timeout")
  expect_identical(in_flight(), base)
})

test_that("operations beyond the cap fail at once and work again once others end (offline)", {
  map_url = silent_map_url()
  base = in_flight()
  withr::local_options(rtailcat.max_operations = base + 2)

  pending = lapply(1:2, function(i) tailcat_address_resolve_async(offline_address(), derp_map_url = map_url, timeout = 60))
  expect_identical(in_flight(), base + 2)

  started = Sys.time()
  cond = tryCatch(tailcat_address_resolve(offline_address(), derp_map_url = map_url, timeout = 30), error = identity)
  expect_lt(as.double(Sys.time() - started, units = "secs"), 1)
  expect_s3_class(cond, "tailcat_failure")
  expect_match(conditionMessage(cond), paste0("the limit of ", base + 2, " operations in flight"), fixed = TRUE)
  expect_match(conditionMessage(cond), "rtailcat.max_operations", fixed = TRUE)
  expect_error(wait_for(tailcat_address_resolve_async(offline_address(), derp_map_url = map_url), 10), "rtailcat.max_operations", class = "tailcat_failure")

  # Validation that fails before an operation starts is not affected by the cap.
  cl = TailcatClient$new(offline_address())
  cl$close()
  expect_error(cl$ping(), class = "tailcat_closed")
  expect_error(tailcat_address_resolve(offline_address(), timeout = -1), class = "tailcat_invalid_argument")
  expect_identical(in_flight(), base + 2)

  outcomes = lapply(pending, function(p) promises::catch(p, identity))
  for (p in pending) {
    tailcat_cancel(p)
  }
  for (o in outcomes) {
    expect_s3_class(wait_for(o, 10), "tailcat_canceled")
  }
  expect_identical(in_flight(), base)
  expect_error(tailcat_address_resolve(offline_address(), derp_map_url = map_url, timeout = 0), class = "tailcat_timeout")
  expect_identical(in_flight(), base)
})

test_that("pending accepts count toward the cap, and canceling or closing releases them", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  port = lst$port
  cl = relay_client(srv$address)
  base = in_flight()
  withr::local_options(rtailcat.max_operations = base + 3)

  pending = lapply(1:3, function(i) lst$accept_async())
  expect_identical(in_flight(), base + 3)
  started = Sys.time()
  cond = tryCatch(lst$accept(timeout = 30), error = identity)
  expect_lt(as.double(Sys.time() - started, units = "secs"), 1)
  expect_s3_class(cond, "tailcat_failure")
  expect_identical(cond$status, 5L)
  expect_match(conditionMessage(cond), "^Could not accept a connection\\.")
  expect_match(conditionMessage(cond), paste0("the limit of ", base + 3, " operations in flight (running or queued) was reached"), fixed = TRUE)
  expect_match(conditionMessage(cond), "rtailcat.max_operations", fixed = TRUE)
  expect_error(wait_for(lst$accept_async(), 10), "rtailcat.max_operations", class = "tailcat_failure")
  expect_error(cl$dial(port, timeout = 30), class = "tailcat_failure")
  expect_error(lst$port, class = "tailcat_failure")
  expect_match(printed(lst), "port: +<unknown>")
  expect_identical(in_flight(), base + 3)

  outcomes = lapply(pending, function(p) promises::catch(p, identity))
  for (p in pending) {
    tailcat_cancel(p)
  }
  for (o in outcomes) {
    expect_s3_class(wait_for(o, 10), "tailcat_canceled")
  }
  expect_identical(in_flight(), base)
  expect_identical(lst$port, port)

  pair = connect_pair(lst, cl, port)
  pair$client$write("after the cap")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "after the cap")
  expect_identical(in_flight(), base)

  reads = lapply(1:3, function(i) pair$server$read_async())
  expect_identical(in_flight(), base + 3)
  expect_error(pair$client$write("x"), class = "tailcat_failure")
  outcomes = lapply(reads, function(p) promises::catch(p, identity))
  pair$server$close()
  for (o in outcomes) {
    expect_s3_class(wait_for(o, 10), "tailcat_closed")
  }
  expect_identical(in_flight(), base)
})
