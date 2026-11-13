# The example code of vignettes/building-on-rtailcat.qmd, extracted into
# inst/examples/ by tools/vignette.R. The examples call TailcatServer$new() and
# TailcatClient$new() without relay arguments; the relay options point them at
# the relay the tests use.

examples_dir = function() {
  system.file("examples", package = "rtailcat", mustWork = TRUE)
}

example_files = c("wormhole", "progress", "proxy")

load_examples = function(env = parent.frame()) {
  withr::local_options(rtailcat.region = relay_region(), rtailcat.derp_map_url = relay_derp_map_url(), .local_envir = env)
  env = new.env(parent = asNamespace("rtailcat"))
  for (f in example_files) {
    sys.source(file.path(examples_dir(), paste0(f, ".R")), envir = env)
  }
  env
}

# Runs example code in a child process, with its messages sent to stdout.
example_child = function(code) {
  child_r(c(
    paste0("examples = ", deparse(examples_dir())),
    "options(rtailcat.region = region, rtailcat.derp_map_url = derp_map_url)",
    paste0("for (f in ", deparse(example_files), ") sys.source(file.path(examples, paste0(f, '.R')), envir = globalenv())"),
    "withCallingHandlers({",
    code,
    "}, message = function(m) {",
    "  cat(sub('\\n?$', '\\n', conditionMessage(m)))",
    "  invokeRestart('muffleMessage')",
    "})"
  ))
}

child_address = function(proc) {
  pattern = "tc[A-Za-z0-9_-]{40,}"
  lines = wait_child_line(proc, pattern)
  found = regmatches(lines, regexpr(pattern, lines))
  if (length(found) == 0) {
    stop("the child printed no address:\n", paste(c(lines, proc$read_all_error_lines()), collapse = "\n"))
  }
  found[[1]]
}

test_that("the example files parse and define the documented functions", {
  ex = load_examples()
  fns = c(
    "wormhole_send", "wormhole_receive",
    "progress_monitor", "progress_record", "progress_data", "progress_stop", "progress_app",
    "progress_reporter", "progress_report", "progress_done",
    "proxy_share", "proxy_open", "proxy_close"
  )
  for (fn in fns) {
    expect_true(is.function(ex[[fn]]), label = fn)
  }
})

test_that("wormhole sends an object and refuses one over max_bytes", {
  skip_relay()
  skip_if_not_installed("processx")
  ex = load_examples()

  child = example_child("wormhole_send(mtcars, timeout = 60)")
  got = suppressMessages(ex$wormhole_receive(child_address(child), timeout = 60))
  expect_identical(got, mtcars)
  expect_match(paste(child_finish(child)$stdout, collapse = "\n"), "Sent")

  child = example_child("wormhole_send(mtcars, timeout = 60)")
  cond = tryCatch(
    ex$wormhole_receive(child_address(child), max_bytes = 100, timeout = 60),
    error = identity
  )
  expect_s3_class(cond, "tailcat_failure")
  expect_match(conditionMessage(cond), "more than `max_bytes`", fixed = TRUE)
  out = child_finish(child)
  expect_match(paste(c(out$stdout, out$stderr), collapse = "\n"), "did not confirm")
})

test_that("progress collects reports and drops oversized ones", {
  skip_relay()
  ex = load_examples()
  m = suppressMessages(ex$progress_monitor())
  withr::defer(ex$progress_stop(m))

  reporter = ex$progress_reporter(m$server$address, job = "a")
  withr::defer(ex$progress_done(reporter))
  for (i in 1:5) {
    expect_true(ex$progress_report(reporter, iter = i, loss = 1 / i))
  }
  expect_true(run_until(function() length(m$events) == 5, 20))
  d = ex$progress_data(m)
  expect_identical(d$job, rep("a", 5))
  expect_identical(d$seq, 1:5)
  expect_equal(d$loss, 1 / (1:5))

  expect_warning(expect_false(ex$progress_report(reporter, note = strrep("x", 2000))), "1232")
})

# Runs an HTTP client in a separate process, because the proxy answers its
# requests on this session's event loop.
proxy_get = function(url, ...) {
  fetch = callr::r_bg(function(url, args) {
    handle = do.call(curl::new_handle, args)
    res = curl::curl_fetch_memory(url, handle = handle)
    list(status = res$status_code, body = rawToChar(res$content))
  }, list(url = url, args = list(...)))
  run_until(function() !fetch$is_alive(), 30)
  fetch$get_result()
}

test_that("proxy forwards requests to an app on the other side", {
  skip_relay()
  skip_if_not_installed("callr")
  skip_if_not_installed("httpuv")
  skip_if_not_installed("curl")
  ex = load_examples()

  app_port = httpuv::randomPort()
  app = callr::r_bg(function(port) {
    httpuv::runServer("127.0.0.1", port, list(call = function(req) {
      body = rawToChar(req$rook.input$read())
      list(
        status = 200L,
        headers = list("Content-Type" = "text/plain"),
        body = paste(req$REQUEST_METHOD, req$PATH_INFO, req$QUERY_STRING, body)
      )
    }))
  }, list(port = app_port))
  withr::defer(app$kill())

  child = example_child(paste0("srv = proxy_share(", app_port, "); tailcat_run(timeout = 120)"))
  withr::defer(child$kill())

  port = httpuv::randomPort()
  p = suppressMessages(ex$proxy_open(child_address(child), port = port))
  withr::defer(ex$proxy_close(p))
  url = paste0("http://127.0.0.1:", port)

  res = proxy_get(paste0(url, "/a/b?x=1"))
  expect_identical(res$status, 200L)
  expect_identical(res$body, "GET /a/b ?x=1 ")

  res = proxy_get(paste0(url, "/post"), postfields = "hello")
  expect_identical(res$body, "POST /post  hello")

  app$kill()
  res = proxy_get(paste0(url, "/gone"))
  expect_identical(res$status, 502L)
  expect_match(res$body, "could not reach the app")
})

