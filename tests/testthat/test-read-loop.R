test_that("read_loop() delivers TCP chunks in order and calls on_end at the end of the stream", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  state = new.env()
  state$chunks = list()
  state$ended = FALSE
  expect_identical(pair$server$read_loop(
    function(data) state$chunks[[length(state$chunks) + 1]] = data,
    on_end = function() state$ended = TRUE
  ), pair$server)
  expect_match(printed(pair$server), "state:   open (reading)", fixed = TRUE)
  expect_error(pair$server$read_loop(identity), "already in a read loop", class = "tailcat_failure")

  big = as.raw(rep_len(0:255, 200000))
  pair$client$write(big)
  pair$client$close_write()
  expect_true(run_until(function() state$ended, 30))
  expect_identical(do.call(c, state$chunks), big)
  expect_false(pair$server$is_closed)
  expect_no_match(printed(pair$server), "reading", fixed = TRUE)
  expect_identical(pair$server$read_loop(identity), pair$server)
})

test_that("read_loop(messages = TRUE) delivers whole messages and waits for promises", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)

  state = new.env()
  state$got = character()
  state$ended = FALSE
  pair$server$read_loop(
    function(msg) {
      promises::promise(function(resolve, reject) {
        later::later(function() {
          state$got = c(state$got, msg)
          resolve(NULL)
        }, delay = if (msg == "first") 0.3 else 0)
      })
    },
    on_end = function() state$ended = TRUE,
    as = "text",
    messages = TRUE
  )
  for (msg in c("first", "second", strrep("x", 100000), "")) {
    pair$client$write_message(msg)
  }
  pair$client$close_write()
  expect_true(run_until(function() state$ended, 30))
  expect_identical(state$got, c("first", "second", strrep("x", 100000), ""))
})

test_that("read_loop() delivers UDP datagrams and stop_reading() ends it without closing", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0, network = "udp")
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port, network = "udp")

  state = new.env()
  state$got = list()
  pair$server$read_loop(function(d) state$got[[length(state$got) + 1]] = d)
  for (i in 1:3) {
    pair$client$write(as.raw(rep(i, 10)))
  }
  expect_true(run_until(function() length(state$got) == 3, 30))
  expect_identical(state$got, lapply(1:3, function(i) as.raw(rep(i, 10))))

  expect_identical(pair$server$stop_reading(), pair$server)
  expect_identical(pair$server$stop_reading(), pair$server)
  later::run_now(0.2)
  expect_false(pair$server$is_closed)
  expect_no_match(printed(pair$server), "reading", fixed = TRUE)
  pair$client$write(as.raw(9))
  expect_identical(pair$server$read(timeout = 20), as.raw(9))
  expect_identical(state$got, lapply(1:3, function(i) as.raw(rep(i, 10))))
})

test_that("read_loop() reports callback errors and bad messages, and closes the connection", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, lst$port)
  state = new.env()
  pair$server$read_loop(function(data) stop("boom"), on_error = function(cond) state$cond = cond)
  pair$client$write("x")
  expect_true(run_until(function() !is.null(state$cond), 30))
  expect_match(conditionMessage(state$cond), "boom")
  expect_true(pair$server$is_closed)

  pair = connect_pair(lst, cl, lst$port)
  state = new.env()
  pair$server$read_loop(
    function(data) promises::promise_reject(simpleError("rejected")),
    on_error = function(cond) state$cond = cond
  )
  pair$client$write("x")
  expect_true(run_until(function() !is.null(state$cond), 30))
  expect_match(conditionMessage(state$cond), "rejected")
  expect_true(pair$server$is_closed)

  pair = connect_pair(lst, cl, lst$port)
  state = new.env()
  pair$server$read_loop(identity, on_error = function(cond) state$cond = cond, messages = TRUE, max_bytes = 3)
  pair$client$write_message("too long")
  expect_true(run_until(function() !is.null(state$cond), 30))
  expect_s3_class(state$cond, "tailcat_failure")
  expect_identical(state$cond$bytes, 4L)
  expect_true(pair$server$is_closed)

  pair = connect_pair(lst, cl, lst$port)
  pair$server$read_loop(function(data) stop("unreported"))
  pair$client$write("x")
  expect_warning(run_until(function() FALSE, 2), "error in the read loop: unreported")
})

test_that("closing the connection or its owner ends read_loop() quietly", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  pair = connect_pair(lst, cl, lst$port)
  state = new.env()
  state$errors = 0
  pair$server$read_loop(identity, on_error = function(cond) state$errors = state$errors + 1)
  pair$server$close()
  expect_no_warning(run_until(function() FALSE, 1))
  expect_identical(state$errors, 0)
  expect_error(pair$server$read_loop(identity), class = "tailcat_closed")

  pair = connect_pair(lst, cl, lst$port)
  pair$client$read_loop(identity, on_error = function(cond) state$errors = state$errors + 1)
  cl$close()
  expect_no_warning(run_until(function() FALSE, 1))
  expect_identical(state$errors, 0)
})

test_that("read_loop() checks its arguments", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  pair = connect_pair(lst, cl, lst$port)
  expect_error(pair$server$read_loop("f"), "callback", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_loop(identity, on_error = 1), "on_error", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_loop(identity, on_end = 1), "on_end", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_loop(identity, messages = NA), "messages", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_loop(identity, as = "chr"), "as", class = "tailcat_invalid_argument")
  expect_error(pair$server$read_loop(identity, max_bytes = -1), "max_bytes", class = "tailcat_invalid_argument")
  expect_no_match(printed(pair$server), "reading", fixed = TRUE)
})
