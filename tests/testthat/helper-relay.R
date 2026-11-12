# Builds and starts the local test relay; called from setup-relay.R. Everything
# it writes goes to a temporary directory, apart from Go's own build and
# module caches. The relay process is stopped when the test run ends.

start_test_relay = function(env = testthat::teardown_env()) {
  if (!requireNamespace("processx", quietly = TRUE)) {
    stop("the processx package is not installed")
  }
  module = normalizePath(testthat::test_path("..", "relay"), mustWork = FALSE)
  if (!file.exists(file.path(module, "go.mod"))) {
    stop("tests/relay/go.mod was not found")
  }
  go = find_go()
  if (!nzchar(go)) {
    stop("Go was not found (set RTAILCAT_GO or put go on the PATH)")
  }

  dir = tempfile("rtailcat-relay-")
  dir.create(dir)
  withr::defer(unlink(dir, recursive = TRUE), envir = env)

  t0 = Sys.time()
  bin = file.path(dir, if (.Platform$OS.type == "windows") "capitest.exe" else "capitest")
  go_env = c(
    "current",
    GOTOOLCHAIN = Sys.getenv("GOTOOLCHAIN", "local"),
    GOWORK = "off",
    GOFLAGS = "-mod=readonly"
  )
  built = processx::run(
    go, c("build", "-trimpath", "-o", bin, "github.com/tailscale/tailcat/internal/capitest"),
    wd = module, env = go_env, timeout = 900, error_on_status = FALSE
  )
  if (built$status != 0 || !file.exists(bin)) {
    stop("building the relay failed: ", last_line(built$stderr))
  }
  build_secs = as.double(Sys.time() - t0, units = "secs")

  cert = make_test_cert(dir, go, go_env)

  relay = processx::process$new(
    bin, c("-cert", file.path(dir, "cert.pem"), "-key", file.path(dir, "key.pem")),
    stdin = "|", stdout = "|", stderr = file.path(dir, "relay.log"),
    cleanup = TRUE, cleanup_tree = TRUE
  )
  withr::defer(stop_test_relay(relay), envir = env, priority = "first")

  line = ""
  deadline = Sys.time() + 30
  while (!nzchar(line) && Sys.time() < deadline && relay$is_alive()) {
    relay$poll_io(1000)
    line = paste(relay$read_output_lines(), collapse = "")
  }
  if (!nzchar(line)) {
    stop("the relay did not start: ", last_line(paste(readLines(file.path(dir, "relay.log"), warn = FALSE), collapse = "\n")))
  }
  info = jsonlite::fromJSON(line, simplifyVector = FALSE)
  if (is.null(info$region)) {
    stop("the relay did not report a region")
  }
  list(
    region = as.character(jsonlite::toJSON(info$region, auto_unbox = TRUE, digits = NA)),
    how = paste0("relay built in ", format(round(build_secs, 1), nsmall = 1), " s, certificate from ", cert),
    process = relay,
    log = file.path(dir, "relay.log")
  )
}

stop_test_relay = function(relay) {
  if (!relay$is_alive()) {
    return(invisible())
  }
  # The relay exits when its stdin closes; kill it if that takes too long.
  tryCatch(close(relay$get_input_connection()), error = function(e) NULL)
  relay$wait(3000)
  if (relay$is_alive()) {
    relay$kill()
  }
  invisible()
}

find_go = function() {
  candidates = c(
    Sys.getenv("RTAILCAT_GO"),
    Sys.which("go"),
    "/usr/local/go/bin/go", "/opt/homebrew/bin/go", "/usr/local/bin/go",
    file.path(Sys.getenv("HOME"), "go", "bin", "go")
  )
  candidates = candidates[nzchar(candidates) & file.exists(candidates)]
  if (length(candidates) == 0) "" else unname(candidates[[1]])
}

# A self-signed certificate for the relay's test HTTPS service, from the openssl
# command line if available, otherwise from the generator in Go's sources.
make_test_cert = function(dir, go, go_env) {
  openssl = Sys.which("openssl")
  if (nzchar(openssl)) {
    res = processx::run(
      openssl,
      c("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=127.0.0.1",
        "-keyout", file.path(dir, "key.pem"), "-out", file.path(dir, "cert.pem")),
      timeout = 60, error_on_status = FALSE
    )
    if (res$status == 0) {
      return("openssl")
    }
  }
  goroot = trimws(processx::run(go, c("env", "GOROOT"), env = go_env, error_on_status = FALSE)$stdout)
  generator = file.path(goroot, "src", "crypto", "tls", "generate_cert.go")
  if (!file.exists(generator)) {
    stop("no openssl command and Go's generate_cert.go was not found to make a certificate")
  }
  res = processx::run(
    go, c("run", generator, "--host", "127.0.0.1", "--duration", "48h"),
    wd = dir, env = go_env, timeout = 300, error_on_status = FALSE
  )
  if (res$status != 0) {
    stop("generating a certificate failed: ", last_line(res$stderr))
  }
  "Go's generate_cert.go"
}

last_line = function(text) {
  lines = strsplit(trimws(text), "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) "no output" else lines[[length(lines)]]
}
