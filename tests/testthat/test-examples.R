# The example code of vignettes/building-on-rtailcat.qmd, extracted into
# inst/examples/ by tools/vignette.R. The examples call TailcatServer$new() and
# TailcatClient$new() without relay arguments; the relay options point them at
# the relay the tests use.

examples_dir = function() {
  system.file("examples", package = "rtailcat", mustWork = TRUE)
}

example_files = c("wormhole", "remote", "progress")

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
    "wormhole_send", "wormhole_send_file", "wormhole_receive",
    "remote_serve", "remote_connect", "remote_eval", "remote_call", "remote_close",
    "progress_monitor", "progress_record", "progress_data", "progress_stop", "progress_app",
    "progress_reporter", "progress_report", "progress_done"
  )
  for (fn in fns) {
    expect_true(is.function(ex[[fn]]), label = fn)
  }
})

test_that("wormhole refuses unsafe file names and existing files", {
  ex = load_examples()
  dir = withr::local_tempdir()
  for (name in c("../x", "a/b", "", ".", "..")) {
    expect_error(ex$wormhole_save(raw(1), name, dir), "unsafe")
  }
  path = ex$wormhole_save(charToRaw("x"), "f.txt", dir)
  expect_identical(readLines(path, warn = FALSE), "x")
  expect_error(ex$wormhole_save(raw(1), "f.txt", dir), "already exists")
})

test_that("wormhole sends an object and a file", {
  skip_relay()
  skip_if_not_installed("processx")
  ex = load_examples()

  child = example_child("wormhole_send(mtcars, timeout = 60)")
  got = suppressMessages(ex$wormhole_receive(child_address(child), timeout = 60))
  expect_identical(got, mtcars)
  expect_match(paste(child_finish(child)$stdout, collapse = "\n"), "Sent")

  src = withr::local_tempfile(fileext = ".csv")
  write.csv(mtcars, src)
  child = example_child(paste0("wormhole_send_file(", deparse(src), ", timeout = 60)"))
  dest = withr::local_tempdir()
  path = suppressMessages(ex$wormhole_receive(child_address(child), dir = dest, timeout = 60))
  expect_identical(basename(path), basename(src))
  expect_identical(readLines(path), readLines(src))
  child_finish(child)
})

test_that("remote evaluates requests from an allowed client", {
  skip_relay()
  skip_if_not_installed("processx")
  ex = load_examples()
  keys = tailcat_keygen()
  child = example_child(c(
    "keys = tailcat_keygen(tempfile())",
    paste0("remote_serve(keys, allowed_clients = ", deparse(keys$public_key), ")")
  ))
  withr::defer(child$kill())

  r = ex$remote_connect(child_address(child), keys)
  expect_identical(ex$remote_eval(r, 1 + 1), 2)
  double = eval(quote(function(x) {
    cat("doubling\n")
    x * 2
  }), globalenv())
  expect_output(expect_identical(ex$remote_call(r, double, 21), 42), "doubling")
  expect_invisible(ex$remote_eval(r, assign("x", 1)))
  expect_false(ex$remote_eval(r, exists("x")))
  expect_error(ex$remote_eval(r, stop("boom")), class = "remote_error")
  expect_identical(ex$remote_eval(r, "still usable"), "still usable")
  ex$remote_close(r)
  expect_true(r$conn$is_closed)
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
