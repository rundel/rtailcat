# One "machine" of a vignette example, started by tools/vignette.R. It loads
# the package and the example code, then runs the cells the parent hands it
# (dir/cell-<i>.R) one at a time, streaming each cell's source and output to
# dir/cell-<i>.out as it happens, so the parent can read an address printed by
# a cell that is still running. Between cells it runs the later event loop, as
# an idle console would. It stops when dir/quit appears. The cells run in the
# global environment, so the driver keeps its own state out of it.

local({
  args = commandArgs(trailingOnly = TRUE)
  dir = args[[1]]
  pkg = args[[2]]
  examples = args[[3]]

  pkgload::load_all(pkg, export_all = FALSE, quiet = TRUE, compile = FALSE)
  options(width = 80, cli.num_colors = 1, cli.dynamic = FALSE, rlang_backtrace_on_error = "none")

  # The vignette code uses the public relays; point it at the test relay instead.
  region = Sys.getenv("RTAILCAT_TEST_REGION")
  if (nzchar(region)) {
    options(rtailcat.region = region, rtailcat.derp_map_url = "none")
  }

  for (f in list.files(examples, pattern = "[.]R$", full.names = TRUE)) {
    sys.source(f, envir = globalenv())
  }

  emit = function(path, lines) {
    cat(paste0(lines, "\n"), file = path, sep = "", append = TRUE)
  }

  as_output = function(text) {
    text = sub("\n$", "", paste(text, collapse = ""))
    paste0("#> ", strsplit(text, "\n", fixed = TRUE)[[1]])
  }

  format_error = function(e) {
    if (inherits(e, "rlang_error")) {
      lines = strsplit(format(e, backtrace = FALSE), "\n", fixed = TRUE)[[1]]
      lines[-1]
    } else if (is.null(conditionCall(e))) {
      paste0("Error: ", conditionMessage(e))
    } else {
      paste0("Error in ", deparse(conditionCall(e))[[1]], ": ", conditionMessage(e))
    }
  }

  run_cell = function(code, out) {
    handler = evaluate::new_output_handler(
      source = function(src, expr) emit(out, sub("\n$", "", src$src)),
      text = function(x) emit(out, as_output(x)),
      message = function(m) emit(out, as_output(conditionMessage(m))),
      warning = function(w) emit(out, as_output(paste0("Warning: ", conditionMessage(w)))),
      error = function(e) emit(out, as_output(paste(format_error(e), collapse = "\n")))
    )
    evaluate::evaluate(code, envir = globalenv(), output_handler = handler, stop_on_error = 0L)
    invisible()
  }

  idle = function(secs) {
    until = Sys.time() + secs
    while (Sys.time() < until) {
      later::run_now(0.05)
    }
  }

  i = 1L
  repeat {
    if (file.exists(file.path(dir, "quit"))) {
      break
    }
    cmd = file.path(dir, paste0("cell-", i, ".R"))
    if (!file.exists(cmd)) {
      idle(0.1)
      next
    }
    if (i > 1L) {
      idle(1)
    }
    out = file.path(dir, paste0("cell-", i, ".out"))
    file.create(out)
    run_cell(paste(readLines(cmd), collapse = "\n"), out)
    file.create(file.path(dir, paste0("cell-", i, ".done")))
    i = i + 1L
  }
})
