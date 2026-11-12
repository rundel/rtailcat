# Starts a local relay (upstream's internal/capitest, built from tests/relay)
# for the network tests, so a developer run needs no internet access. See
# "Local test relay" in CLAUDE.md. RTAILCAT_TEST_RELAY selects the mode.

local({
  mode = tolower(Sys.getenv("RTAILCAT_TEST_RELAY", "auto"))
  if (!mode %in% c("auto", "local", "public")) {
    stop("RTAILCAT_TEST_RELAY must be \"auto\", \"local\", or \"public\", not \"", mode, "\"", call. = FALSE)
  }
  say = function(...) message("rtailcat tests: ", ...)

  # testthat's own skip_on_cran() decides, so the gating matches the tests.
  on_cran = tryCatch({
    testthat::skip_on_cran()
    FALSE
  }, skip = function(e) TRUE)
  if (on_cran) {
    return(invisible())
  }
  if (skip_online_set()) {
    say("network tests skipped (RTAILCAT_SKIP_ONLINE is set)")
    return(invisible())
  }
  if (mode == "public") {
    withr::local_envvar(RTAILCAT_TEST_REGION = NA, .local_envir = testthat::teardown_env())
    say("using the public relays (RTAILCAT_TEST_RELAY=public)")
    return(invisible())
  }
  if (nzchar(Sys.getenv("RTAILCAT_TEST_REGION"))) {
    say("using the relay region given in RTAILCAT_TEST_REGION")
    return(invisible())
  }

  started = tryCatch(start_test_relay(), error = function(e) e)
  if (inherits(started, "error")) {
    if (mode == "local") {
      stop("rtailcat tests: RTAILCAT_TEST_RELAY=local but the local relay could not be started: ", conditionMessage(started), call. = FALSE)
    }
    say("using the public relays, because the local relay could not be started: ", conditionMessage(started))
    return(invisible())
  }
  withr::local_envvar(RTAILCAT_TEST_REGION = started$region, .local_envir = testthat::teardown_env())
  test_relay$process = started$process
  test_relay$log = started$log
  say("using a local relay on 127.0.0.1 (", started$how, ")")
})
