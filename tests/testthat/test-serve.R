test_that("a handler's rejected promise reaches on_error and closes the connection", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  state = new.env()
  state$errors = list()
  lst$serve(
    function(conn) {
      promises::then(conn$read_all_async(timeout = 20, as = "text"), function(msg) {
        if (msg == "boom") {
          stop("async handler failed")
        }
        conn$write(toupper(msg))
        conn$close()
      })
    },
    on_error = function(cond, conn) {
      state$errors[[length(state$errors) + 1L]] = list(cond = cond, conn = conn)
    }
  )

  conn = cl$dial(lst$port, timeout = 30)
  conn$write("fine")
  conn$close_write()
  expect_identical(wait_for(conn$read_all_async(timeout = 20, as = "text"), 25), "FINE")

  conn = cl$dial(lst$port, timeout = 30)
  conn$write("boom")
  conn$close_write()
  expect_true(run_until(function() length(state$errors) == 1L, 30))
  expect_match(conditionMessage(state$errors[[1]]$cond), "async handler failed")
  expect_true(state$errors[[1]]$conn$is_closed)
})

test_that("a rejected handler promise without on_error becomes a warning", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  state = new.env()
  lst$serve(function(conn) {
    state$conn = conn
    promises::promise_reject(simpleError("rejected on purpose"))
  })
  conn = cl$dial(lst$port, timeout = 30)
  expect_warning(run_until(function() FALSE, 3), "rejected on purpose")
  expect_true(state$conn$is_closed)
})

test_that("an accept failure is reported with conn = NULL and the loop keeps serving", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  state = new.env()
  state$errors = list()
  state$served = 0L
  lst$serve(
    function(conn) {
      state$served = state$served + 1L
      conn$close()
    },
    on_error = function(cond, conn) {
      state$errors[[length(state$errors) + 1L]] = list(cond = cond, conn = conn)
    }
  )
  later::run_now(0.1)
  # Cancel the loop's pending accept behind its back, so the accept fails with
  # something other than tailcat_closed.
  rtailcat:::rtc_cancel(lst$.__enclos_env__$private$serve_cancel)
  expect_true(run_until(function() length(state$errors) == 1L, 10))
  expect_s3_class(state$errors[[1]]$cond, "tailcat_canceled")
  expect_null(state$errors[[1]]$conn)
  expect_match(printed(lst), "serving", fixed = TRUE)

  conn = cl$dial(lst$port, timeout = 30)
  expect_true(run_until(function() state$served == 1L, 30))
  conn$close()
  lst$stop_serving()
})

test_that("an on_error callback that fails becomes a warning and the loop keeps serving", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)

  state = new.env()
  state$calls = 0L
  lst$serve(
    function(conn) stop("handler failed"),
    on_error = function(cond, conn) {
      state$calls = state$calls + 1L
      stop("on_error failed too")
    }
  )
  first = cl$dial(lst$port, timeout = 30)
  expect_warning(run_until(function() FALSE, 3), "on_error failed too")
  expect_identical(state$calls, 1L)
  second = cl$dial(lst$port, timeout = 30)
  expect_warning(run_until(function() FALSE, 3), "on_error failed too")
  expect_identical(state$calls, 2L)
  lst$stop_serving()
})

test_that("serve() checks its arguments and refuses a closed listener", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  expect_error(lst$serve(1), class = "tailcat_invalid_argument")
  expect_error(lst$serve(function(conn) NULL, on_error = "x"), class = "tailcat_invalid_argument")
  expect_false(grepl("serving", printed(lst), fixed = TRUE))
  lst$close()
  expect_error(lst$serve(function(conn) NULL), class = "tailcat_closed")
})

test_that("a tailcat error in a handler becomes a warning with the headline and detail", {
  skip_relay()
  srv = relay_server()
  lst = srv$listen(0)
  cl = relay_client(srv$address)
  lst$serve(function(conn) conn$read(timeout = 0.2))
  conn = cl$dial(lst$port, timeout = 30)
  w = NULL
  withCallingHandlers(
    run_until(function() !is.null(w), 10),
    warning = function(cond) {
      w <<- conditionMessage(cond)
      invokeRestart("muffleWarning")
    }
  )
  lines = strsplit(w, "\n", fixed = TRUE)[[1]]
  expect_identical(lines[[1]], "rtailcat: error in the connection handler: Timed out after 0.2 seconds trying to read.")
  expect_length(lines, 2)
  expect_match(lines[[2]], "tailcat: ")
  lst$stop_serving()
  conn$close()
})
