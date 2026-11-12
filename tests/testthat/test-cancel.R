test_that("tailcat_cancel() rejects anything but an rtailcat promise", {
  expect_error(tailcat_cancel(1), class = "tailcat_invalid_argument")
  expect_error(tailcat_cancel(NULL), class = "tailcat_invalid_argument")
  expect_error(tailcat_cancel(promises::promise_resolve(1)), class = "tailcat_invalid_argument")

  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)))
  cl$close()
  pending = cl$ping_async()
  derived = promises::then(pending, identity)
  expect_error(tailcat_cancel(derived), "derived", class = "tailcat_invalid_argument")
  promises::catch(derived, function(e) NULL)
  expect_error(rtc_cancel(1), "cancel handle")
  expect_error(rtc_cancel(new.env()), "cancel handle")
})

test_that("a job that never started returns a cancel handle that does nothing", {
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)))
  cl$close()
  pending = cl$ping_async()
  canceler = attr(pending, "rtailcat_cancel")
  expect_type(canceler, "closure")
  expect_false(canceler())
  expect_identical(withVisible(tailcat_cancel(pending)), list(value = pending, visible = FALSE))
  expect_error(wait_for(pending, 10), class = "tailcat_closed")
  expect_false(canceler())
})

test_that("canceling a pending accept rejects it and leaves the listener usable", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8090)
  cl = relay_client(srv$address)

  pending = lst$accept_async()
  later::run_now(0.2)
  started = Sys.time()
  expect_invisible(tailcat_cancel(pending))
  cond = tryCatch(wait_for(pending, 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_canceled")
  expect_s3_class(cond, "tailcat_error")
  expect_identical(cond$status, 4L)
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)
  expect_false(lst$is_closed)

  pair = connect_pair(lst, cl, 8090)
  pair$client$write("after cancel")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "after cancel")
})

test_that("canceling a pending read leaves the connection readable", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8091)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 8091)

  pending = pair$server$read_async()
  later::run_now(0.2)
  tailcat_cancel(pending)
  tailcat_cancel(pending)
  expect_error(wait_for(pending, 10), class = "tailcat_canceled")
  tailcat_cancel(pending)

  pair$client$write("still here")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "still here")
  pair$server$write("and back")
  expect_identical(pair$client$read(timeout = 20, as = "text"), "and back")
})

test_that("canceling a pending dial rejects it", {
  skip_relay()
  srv = relay_server()
  srv$start()
  address = srv$address
  srv$close()
  cl = relay_client(address)

  pending = cl$dial_async(8092, timeout = 60)
  later::run_now(0.5)
  started = Sys.time()
  tailcat_cancel(pending)
  expect_error(wait_for(pending, 10), class = "tailcat_canceled")
  expect_lt(as.double(Sys.time() - started, units = "secs"), 5)
  expect_false(cl$is_closed)
})

test_that("a stale cancel handle cannot cancel a later operation", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8093)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 8093)

  old = pair$client$write_async("done")
  expect_identical(wait_for(old, 20), 4L)
  expect_identical(pair$server$read(timeout = 20, as = "text"), "done")

  pending = pair$server$read_async(timeout = 20, as = "text")
  later::run_now(0.1)
  expect_false(attr(old, "rtailcat_cancel")())
  expect_invisible(tailcat_cancel(old))
  run_until(function() FALSE, 0.3)
  pair$client$write("later")
  expect_identical(wait_for(pending, 20), "later")
  expect_identical(wait_for(old, 1), 4L)

  info = srv$info_async()
  value = wait_for(info, 10)
  pending = pair$server$read_async(timeout = 20, as = "text")
  tailcat_cancel(info)
  pair$client$write("again")
  expect_identical(wait_for(pending, 20), "again")
  expect_identical(wait_for(info, 1), value)
})

test_that("canceling read_all_async stops at the read in flight", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8094)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, 8094)

  pending = pair$server$read_all_async()
  pair$client$write("partial")
  later::run_now(0.5)
  run_until(function() FALSE, 0.5)
  tailcat_cancel(pending)
  cond = tryCatch(wait_for(pending, 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_canceled")
  expect_identical(as.double(cond$bytes), 7)

  pair$client$write("more")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "more")

  pending = pair$server$read_all_async(as = "text")
  tailcat_cancel(pending)
  cond = tryCatch(wait_for(pending, 10), error = function(e) e)
  expect_s3_class(cond, "tailcat_canceled")
  expect_identical(as.double(cond$bytes), 0)

  pending = pair$server$read_all_async(as = "text")
  pair$client$write("whole")
  pair$client$close_write()
  expect_identical(wait_for(pending, 20), "whole")
})

test_that("stop_serving() ends the serve loop but keeps the listener open", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(8095)
  cl = relay_client(srv$address)

  state = new.env()
  state$seen = character()
  handler = function(tag) {
    force(tag)
    function(conn) {
      state$seen = c(state$seen, tag)
      conn$close()
    }
  }
  lst$serve(handler("first"))
  expect_match(printed(lst), "serving", fixed = TRUE)
  conn = cl$dial(8095, timeout = 30)
  expect_true(run_until(function() length(state$seen) == 1L, 30))
  conn$close()

  expect_invisible(lst$stop_serving())
  lst$stop_serving()
  later::run_now(0.5)
  expect_false(grepl("serving", printed(lst), fixed = TRUE))
  expect_false(lst$is_closed)

  pair = connect_pair(lst, cl, 8095)
  pair$client$write("manual")
  expect_identical(pair$server$read(timeout = 20, as = "text"), "manual")
  expect_identical(state$seen, "first")

  lst$serve(handler("second"))
  conn = cl$dial(8095, timeout = 30)
  expect_true(run_until(function() length(state$seen) == 2L, 30))
  expect_identical(state$seen, c("first", "second"))
  conn$close()
  lst$stop_serving()
})
