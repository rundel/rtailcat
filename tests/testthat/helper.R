skip_online_set = function() {
  tolower(Sys.getenv("RTAILCAT_SKIP_ONLINE")) %in% c("1", "true", "yes")
}

wait_for = function(promise, timeout = 30) {
  state = new.env()
  state$done = FALSE
  promises::then(
    promise,
    onFulfilled = function(value) {
      state$value = value
      state$done = TRUE
    },
    onRejected = function(error) {
      state$error = error
      state$done = TRUE
    }
  )
  run_until(function() state$done, timeout)
  if (!state$done) {
    stop("promise did not settle within ", timeout, " seconds")
  }
  if (!is.null(state$error)) {
    stop(state$error)
  }
  state$value
}

run_until = function(condition, timeout = 30) {
  deadline = Sys.time() + timeout
  while (!condition() && Sys.time() < deadline) {
    later::run_now(0.05)
  }
  condition()
}

local_server = function(env = parent.frame(), ...) {
  srv = TailcatServer$new(...)
  withr::defer(srv$close(), envir = env)
  srv
}

local_client = function(address, env = parent.frame(), ...) {
  cl = TailcatClient$new(address, ...)
  withr::defer(cl$close(), envir = env)
  cl
}

connect_pair = function(listener, client, port, network = "tcp", timeout = 30) {
  pending = listener$accept_async(timeout = timeout)
  client_conn = client$dial(port, network = network, timeout = timeout)
  if (network == "udp") {
    client_conn$write(as.raw(0))
  }
  server_conn = wait_for(pending, timeout)
  if (network == "udp") {
    server_conn$read(timeout = timeout)
  }
  list(client = client_conn, server = server_conn)
}

printed = function(x) {
  paste(utils::capture.output(print(x)), collapse = "\n")
}

# Network tests use the relay region in RTAILCAT_TEST_REGION (a DERP region as
# JSON, set by setup-relay.R for the local relay), or the public relays when
# it is empty.
relay_region = function() {
  region = Sys.getenv("RTAILCAT_TEST_REGION")
  if (nzchar(region)) jsonlite::fromJSON(region, simplifyVector = FALSE) else NULL
}

# Set by setup-relay.R when it starts the local relay.
test_relay = new.env(parent = emptyenv())

skip_relay = function() {
  testthat::skip_on_cran()
  if (skip_online_set()) {
    testthat::skip("RTAILCAT_SKIP_ONLINE is set")
  }
  # Without this, every remaining network test would wait out its own timeout.
  if (!is.null(test_relay$process) && !test_relay$process$is_alive()) {
    stop("the local test relay has exited (status ", test_relay$process$get_exit_status(), "); see ", test_relay$log, call. = FALSE)
  }
  if (is.null(relay_region())) {
    testthat::skip_if_offline("tailcat.dev")
  }
}

relay_server = function(env = parent.frame(), ...) {
  local_server(env = env, region = relay_region(), ...)
}

relay_client = function(address, env = parent.frame(), ...) {
  local_client(address, env = env, derp_map_url = relay_derp_map_url(), ...)
}

relay_derp_map_url = function() {
  if (is.null(relay_region())) NULL else "none"
}

cbor_head = function(major, n) {
  if (n < 24) {
    return(as.raw(major * 32 + n))
  }
  if (n < 256) {
    return(as.raw(c(major * 32 + 24, n)))
  }
  as.raw(c(major * 32 + 25, n %/% 256, n %% 256))
}

cbor = function(x) {
  if (is.null(x)) {
    return(as.raw(0xf6))
  }
  if (is.raw(x)) {
    return(c(cbor_head(2, length(x)), x))
  }
  if (is.logical(x)) {
    return(as.raw(if (x) 0xf5 else 0xf4))
  }
  if (is.character(x)) {
    bytes = charToRaw(enc2utf8(x))
    return(c(cbor_head(3, length(bytes)), bytes))
  }
  if (is.numeric(x)) {
    return(if (x >= 0) cbor_head(0, x) else cbor_head(1, -1 - x))
  }
  parts = if (is.null(names(x))) {
    lapply(x, cbor)
  } else {
    Map(function(k, v) c(cbor(k), cbor(v)), names(x), x)
  }
  c(cbor_head(if (is.null(names(x))) 4 else 5, length(x)), unlist(parts, use.names = FALSE))
}

base64url_encode = function(x) {
  gsub("=+$", "", chartr("+/", "-_", jsonlite::base64_enc(x)))
}

base64url_decode = function(x) {
  x = chartr("-_", "+/", x)
  jsonlite::base64_dec(paste0(x, strrep("=", (4 - nchar(x) %% 4) %% 4)))
}

tc_address = function(fields) {
  paste0("tc", base64url_encode(cbor(fields)))
}

# Replaces the 32-byte pre-shared key (CBOR key "q") inside a real address.
tamper_psk = function(address) {
  bytes = base64url_decode(substring(address, 3))
  marker = as.raw(c(0x61, 0x71, 0x58, 0x20))
  starts = which(vapply(seq_len(length(bytes) - 35), function(i) identical(bytes[i:(i + 3)], marker), logical(1)))
  stopifnot(length(starts) == 1)
  idx = starts + 4:35
  repeat {
    psk = as.raw(sample(0:255, 32, replace = TRUE))
    if (!identical(psk, bytes[idx])) break
  }
  bytes[idx] = psk
  paste0("tc", base64url_encode(bytes))
}

# Runs R code in a child process with the rtailcat under test loaded (from the
# source tree under devtools::test(), otherwise the installed package).
child_r = function(code) {
  path = getNamespaceInfo("rtailcat", "path")
  load = if (dir.exists(file.path(path, "src"))) {
    paste0("pkgload::load_all(", deparse(path), ", quiet = TRUE, compile = FALSE)")
  } else {
    paste0("library(rtailcat, lib.loc = ", deparse(dirname(path)), ")")
  }
  setup = c(
    "region = Sys.getenv('RTAILCAT_TEST_REGION')",
    "region = if (nzchar(region)) jsonlite::fromJSON(region, simplifyVector = FALSE) else NULL",
    "derp_map_url = if (is.null(region)) NULL else 'none'"
  )
  processx::process$new(
    file.path(R.home("bin"), "Rscript"), c("-e", paste(c(load, setup, code), collapse = "\n")),
    stdout = "|", stderr = "|", cleanup = TRUE
  )
}

wait_child_line = function(proc, pattern, timeout = 60) {
  deadline = Sys.time() + timeout
  seen = character()
  while (Sys.time() < deadline && proc$is_alive()) {
    proc$poll_io(200)
    seen = c(seen, proc$read_output_lines())
    if (any(grepl(pattern, seen))) {
      return(seen)
    }
  }
  c(seen, proc$read_output_lines())
}

child_finish = function(proc, timeout = 60) {
  proc$wait(timeout * 1000)
  if (proc$is_alive()) {
    proc$kill()
  }
  list(stdout = proc$read_all_output_lines(), stderr = proc$read_all_error_lines())
}

# A relay map URL on 127.0.0.1 whose server accepts connections but never
# answers, so anything that needs the relay map waits without network access.
# Lets a timeout = 0 poll time out deterministically, whatever tailcat has
# cached in the process.
# R closes connections nothing refers to, so the sockets are kept here.
silent_sockets = new.env(parent = emptyenv())

silent_map_url = function(env = parent.frame()) {
  for (port in sample(20000:45000, 20)) {
    sock = tryCatch(serverSocket(port), error = function(e) NULL)
    if (!is.null(sock)) {
      key = as.character(port)
      silent_sockets[[key]] = sock
      withr::defer({
        close(silent_sockets[[key]])
        rm(list = key, envir = silent_sockets)
      }, envir = env)
      return(paste0("http://127.0.0.1:", port, "/derpmap.json"))
    }
  }
  testthat::skip("no free local port for a silent relay map server")
}
