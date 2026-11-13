# Keeps vignettes/building-on-rtailcat.qmd and inst/examples/ in sync and
# checks the vignette's recorded output. Run from the package root:
#
#   Rscript tools/vignette.R            # report differences, exit 1 if any
#   Rscript tools/vignette.R --update   # rewrite inst/examples/ and the output
#   Rscript tools/vignette.R remote     # limit the run to some examples
#
# The vignette is the source. Cells labeled <example>-def-<name> define the
# example functions and are concatenated into inst/examples/<example>.R. Cells
# with a `class-source` option are usage code for that side (machine); each
# side of an example runs in its own R process (tools/vignette-side.R) against
# a local test relay, in document order. A cell with `blocks: true` waits on
# the other side, so later cells start without waiting for it to finish; a
# cell with `run: false` is not run. Each cell's code is the code without its
# `#>` lines, and its new content is the code interleaved with the output.
#
# Values that change from run to run are replaced with placeholders: tailcat
# addresses become tcAbC...xYz, tcDeF...uVw, ... and public keys nodekey:3f1c...9a0e,
# ... in order of first appearance within an example. Before a cell runs, the
# placeholders in its code are replaced with the real values seen so far, so
# the vignette can show `wormhole_receive("tcAbC...xYz")`.
#
# Needs q2r (github.com/rundel/q2r), pkgload, processx, evaluate, withr, Go.

address_placeholders = c("tcAbC...xYz", "tcDeF...uVw", "tcGhI...rSt", "tcJkL...oPq")
key_placeholders = c("nodekey:3f1c...9a0e", "nodekey:b7d2...41c5", "nodekey:5e80...c3f7", "nodekey:a94b...07d2")
address_pattern = "tc[A-Za-z0-9_-]{40,}"
key_pattern = "nodekey:[0-9a-f]{64}"

vignette_path = file.path("vignettes", "building-on-rtailcat.qmd")
side_script = file.path("tools", "vignette-side.R")
examples_dir = file.path("inst", "examples")

main = function(args) {
  if (!file.exists("DESCRIPTION") || !file.exists(vignette_path)) {
    stop("run tools/vignette.R from the package root", call. = FALSE)
  }
  for (pkg in c("q2r", "pkgload", "processx", "evaluate", "withr", "jsonlite")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("tools/vignette.R needs the ", pkg, " package", call. = FALSE)
    }
  }
  update = "--update" %in% args
  only = setdiff(args, "--update")

  cells = vignette_cells(vignette_path)
  defs = example_files(cells)
  ok = sync_examples(defs, update)

  usage = Filter(function(cell) !is.null(cell$side) && !identical(cell$opts$run, FALSE), cells)
  names = unique(vapply(usage, function(cell) cell$example, character(1)))
  if (length(only) > 0) {
    unknown = setdiff(only, names)
    if (length(unknown) > 0) {
      stop("unknown example: ", paste(unknown, collapse = ", "), call. = FALSE)
    }
    names = only
  }

  root = normalizePath(".")
  message("Loading the package (compiling if needed)")
  pkgload::load_all(root, export_all = FALSE, quiet = TRUE)

  relay_env = new.env()
  sys.source(file.path("tests", "testthat", "helper-relay.R"), envir = relay_env)
  relay = relay_env$start_test_relay(env = environment())
  message("Using a local relay (", relay$how, ")")

  defs_dir = tempfile("vignette-examples-")
  dir.create(defs_dir)
  withr::defer(unlink(defs_dir, recursive = TRUE))
  for (name in names(defs)) {
    writeLines(defs[[name]], file.path(defs_dir, paste0(name, ".R")))
  }

  new_code = list()
  for (name in names) {
    message("Running ", name)
    example_cells = Filter(function(cell) cell$example == name, usage)
    new_code = c(new_code, run_example(example_cells, root, defs_dir, relay$region))
  }

  changed = character()
  for (cell in usage) {
    if (!cell$label %in% names(new_code)) {
      next
    }
    if (!identical(cell$code, new_code[[cell$label]])) {
      changed = c(changed, cell$label)
      if (!update) {
        show_diff(cell$label, cell$code, new_code[[cell$label]])
      }
    }
  }
  if (length(changed) > 0 && update) {
    rewrite_cells(vignette_path, new_code[changed])
    message("Updated the output of ", length(changed), " cell(s): ", paste(changed, collapse = ", "))
  }
  if (length(changed) == 0) {
    message("The recorded output is up to date")
  }
  if (!update && (!ok || length(changed) > 0)) {
    message("Run `Rscript tools/vignette.R --update` to apply these changes")
    quit(status = 1)
  }
  invisible()
}

vignette_cells = function(path) {
  doc = q2r::read_qmd(path, quiet = TRUE)
  blocks = Filter(q2r::is_code_cell, q2r::select_nodes(doc, is(q2r::pandoc_code_block)))
  if (length(blocks) == 0) {
    stop("no code cells found in ", path, call. = FALSE)
  }
  lapply(blocks, function(block) {
    label = q2r::cell_label(block)
    opts = q2r::cell_options(block)
    def = regmatches(label, regexec("^([a-z]+)-def-", label))[[1]]
    list(
      label = label,
      opts = opts,
      code = q2r::cell_code(block),
      def = if (length(def) == 2) def[[2]] else NULL,
      example = sub("-.*$", "", label),
      side = opts[["class-source"]]
    )
  })
}

example_files = function(cells) {
  defs = Filter(function(cell) !is.null(cell$def), cells)
  names = unique(vapply(defs, function(cell) cell$def, character(1)))
  header = paste0(
    "# Generated from ", vignette_path, " by tools/vignette.R; edit the vignette, not this file.\n"
  )
  out = lapply(names, function(name) {
    code = vapply(Filter(function(cell) cell$def == name, defs), function(cell) cell$code, character(1))
    paste0(header, "\n", paste(code, collapse = "\n\n"), "\n")
  })
  stats::setNames(out, names)
}

sync_examples = function(defs, update) {
  ok = TRUE
  for (name in names(defs)) {
    path = file.path(examples_dir, paste0(name, ".R"))
    current = if (file.exists(path)) paste0(paste(readLines(path), collapse = "\n"), "\n") else ""
    if (identical(current, defs[[name]])) {
      next
    }
    if (update) {
      dir.create(examples_dir, recursive = TRUE, showWarnings = FALSE)
      writeLines(sub("\n$", "", defs[[name]]), path)
      message("Updated ", path)
    } else {
      message(path, " is out of date")
      ok = FALSE
    }
  }
  stale = setdiff(sub("[.]R$", "", list.files(examples_dir, pattern = "[.]R$")), names(defs))
  for (name in stale) {
    message(file.path(examples_dir, paste0(name, ".R")), " has no cells in the vignette")
    ok = FALSE
  }
  ok
}

# Runs the cells of one example, one process per side, and returns the new
# content of each cell, named by label.
run_example = function(cells, root, defs_dir, region) {
  keep = Sys.getenv("RTAILCAT_VIGNETTE_KEEP")
  if (nzchar(keep)) {
    work = tempfile("vignette-run-", tmpdir = normalizePath(keep))
    message("Keeping the run directory ", work)
  } else {
    work = tempfile("vignette-run-")
    withr::defer(unlink(work, recursive = TRUE))
  }
  dir.create(work)
  home = file.path(work, "home")
  dir.create(home)

  sides = unique(vapply(cells, function(cell) cell$side, character(1)))
  procs = list()
  for (side in sides) {
    dir.create(file.path(work, side, "wd"), recursive = TRUE)
    procs[[side]] = processx::process$new(
      file.path(R.home("bin"), "Rscript"),
      c(normalizePath(side_script), file.path(work, side), root, defs_dir),
      wd = file.path(work, side, "wd"),
      env = c("current", HOME = home, R_USER = home, RTAILCAT_TEST_REGION = region),
      stdout = file.path(work, side, "log"), stderr = "2>&1",
      cleanup = TRUE, cleanup_tree = TRUE
    )
  }
  withr::defer(for (proc in procs) if (proc$is_alive()) proc$kill())

  index = integer(length(cells))
  counter = stats::setNames(integer(length(sides)), sides)
  out_file = function(k) file.path(work, cells[[k]]$side, paste0("cell-", index[[k]], ".out"))
  done = function(k) file.exists(file.path(work, cells[[k]]$side, paste0("cell-", index[[k]], ".done")))
  check_alive = function() {
    for (side in sides) {
      if (!procs[[side]]$is_alive()) {
        log = readLines(file.path(work, side, "log"), warn = FALSE)
        stop("the ", side, " process exited:\n", paste(utils::tail(log, 20), collapse = "\n"), call. = FALSE)
      }
    }
  }
  wait = function(condition, what, timeout = 120) {
    deadline = Sys.time() + timeout
    while (!condition()) {
      check_alive()
      if (Sys.time() > deadline) {
        stop("timed out waiting for ", what, call. = FALSE)
      }
      Sys.sleep(0.1)
    }
  }
  started = function() seq_len(sum(index > 0))
  outputs = function() {
    lapply(started(), function(k) {
      path = out_file(k)
      if (file.exists(path)) readLines(path, warn = FALSE) else character()
    })
  }

  for (k in seq_along(cells)) {
    cell = cells[[k]]
    earlier = seq_len(k - 1)
    wait(function() {
      all(vapply(earlier, function(j) {
        done(j) || (isTRUE(cells[[j]]$opts$blocks) && cells[[j]]$side != cell$side)
      }, logical(1)))
    }, paste("the cells before", cell$label))

    code = strip_output(cell$code)
    used = c(address_placeholders, key_placeholders)
    used = used[vapply(used, function(p) grepl(p, code, fixed = TRUE), logical(1))]
    if (length(used) > 0) {
      wait(function() all(used %in% placeholder_map(outputs())$placeholder), paste("the values used in", cell$label), 60)
      map = placeholder_map(outputs())
      for (p in used) {
        code = gsub(p, map$value[map$placeholder == p], code, fixed = TRUE)
      }
    }

    counter[[cell$side]] = counter[[cell$side]] + 1L
    index[[k]] = counter[[cell$side]]
    cmd = file.path(work, cell$side, paste0("cell-", index[[k]], ".R"))
    writeLines(code, paste0(cmd, ".tmp"))
    file.rename(paste0(cmd, ".tmp"), cmd)
  }

  waiting = Filter(function(k) !isTRUE(cells[[k]]$opts$blocks), seq_along(cells))
  wait(function() all(vapply(waiting, done, logical(1))), "the last cells")

  # Blocking cells that never return (a server) are stopped once their output
  # has been quiet for a while.
  last = NULL
  quiet_since = Sys.time()
  wait(function() {
    now = outputs()
    if (!identical(now, last)) {
      last <<- now
      quiet_since <<- Sys.time()
    }
    all(vapply(seq_along(cells), done, logical(1))) || Sys.time() - quiet_since > 3
  }, "the blocking cells to finish")

  for (side in sides) {
    file.create(file.path(work, side, "quit"))
  }
  final = outputs()
  map = placeholder_map(final)
  result = lapply(seq_along(cells), function(k) normalize(final[[k]], map))
  stats::setNames(result, vapply(cells, function(cell) cell$label, character(1)))
}

strip_output = function(code) {
  lines = strsplit(code, "\n", fixed = TRUE)[[1]]
  paste(lines[!grepl("^#>", lines)], collapse = "\n")
}

# Real values in order of first appearance, and their placeholders.
placeholder_map = function(outputs) {
  text = paste(unlist(outputs), collapse = "\n")
  find = function(pattern) unique(regmatches(text, gregexpr(pattern, text))[[1]])
  addresses = find(address_pattern)
  keys = find(key_pattern)
  if (length(addresses) > length(address_placeholders) || length(keys) > length(key_placeholders)) {
    stop("more addresses or keys than placeholders; add some to tools/vignette.R", call. = FALSE)
  }
  data.frame(
    value = c(addresses, keys),
    placeholder = c(address_placeholders[seq_along(addresses)], key_placeholders[seq_along(keys)])
  )
}

normalize = function(lines, map) {
  for (i in seq_len(nrow(map))) {
    lines = gsub(map$value[[i]], map$placeholder[[i]], lines, fixed = TRUE)
  }
  while (length(lines) > 0 && !nzchar(trimws(lines[[length(lines)]]))) {
    lines = lines[-length(lines)]
  }
  paste(lines, collapse = "\n")
}

show_diff = function(label, old, new) {
  a = tempfile()
  b = tempfile()
  writeLines(old, a)
  writeLines(new, b)
  diff = suppressWarnings(system2("diff", c("-u", "--label", "recorded", "--label", "now", a, b), stdout = TRUE))
  message("Output of `", label, "` differs:")
  message(paste(diff, collapse = "\n"))
  unlink(c(a, b))
}

# Replaces the code (everything after the `#|` option lines) of the given
# cells, through q2r's tree-sitter tree, which writes every other byte of the
# file back unchanged.
rewrite_cells = function(path, new_code) {
  tree = q2r::read_qmd(path, ast = "ts", quiet = TRUE)
  for (label in names(new_code)) {
    marker = paste0("#| label: ", label, "\n")
    code = new_code[[label]]
    tree = q2r::replace_nodes(
      tree,
      kind == "pandoc_code_block" & grepl(marker, text, fixed = TRUE),
      .with = function(node) q2r::ts_node(kind = node@kind, text = replace_cell_code(node@text, code))
    )
  }
  q2r::write_qmd(tree, path)
}

replace_cell_code = function(text, code) {
  close = max(gregexpr("\n```", text, fixed = TRUE)[[1]])
  head = strsplit(substring(text, 1, close - 1), "\n", fixed = TRUE)[[1]]
  tail = substring(text, close + 1)
  opts = head[seq_len(max(which(grepl("^#\\|", head)), 1))]
  paste0(paste(c(opts, code), collapse = "\n"), "\n", tail)
}

main(commandArgs(trailingOnly = TRUE))
