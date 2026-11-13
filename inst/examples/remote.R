# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R; edit the vignette, not this file.

remote_port = 4405L

remote_serve = function(keys, allowed_clients, max_bytes = 1e8) {
  srv = TailcatServer$new(key = keys, allowed_clients = allowed_clients)
  on.exit(srv$close(), add = TRUE)
  lst = srv$listen(remote_port)
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c(
    "Serving R for {length(allowed_clients)} client{?s} at this address:",
    "{address}"
  ))
  repeat {
    conn = lst$accept()
    cli::cli_inform("Client connected.")
    tryCatch(
      remote_session(conn, max_bytes),
      error = \(e) cli::cli_inform(c("The connection failed:", "x" = "{conditionMessage(e)}"))
    )
    conn$close()
  }
}

remote_session = function(conn, max_bytes) {
  n = 0
  repeat {
    # NULL means the client ended the stream between requests.
    request = conn$read_message(max_bytes = max_bytes)
    if (is.null(request)) {
      break
    }
    reply = request |> unserialize() |> remote_run()
    conn$write_message(serialize(reply, NULL), timeout = 600)
    n = n + 1
  }
  cli::cli_inform("Client disconnected after {n} request{?s}.")
}

remote_run = function(expr) {
  # A fresh environment per request, so requests cannot see each other's variables.
  env = new.env(parent = globalenv())
  output = utils::capture.output({
    result = tryCatch(
      withVisible(eval(expr, env)),
      error = \(e) list(value = NULL, visible = FALSE, error = conditionMessage(e))
    )
  })
  result$output = output
  result
}

remote_connect = function(address, keys) {
  cl = TailcatClient$new(address, key = keys)
  conn = tryCatch(
    cl$dial(remote_port, timeout = 60),
    error = \(e) {
      cl$close()
      stop(e)
    }
  )
  structure(list(client = cl, conn = conn), class = "remote_session")
}

remote_eval = function(session, expr, timeout = 600) {
  remote_request(session, substitute(expr), timeout)
}

remote_call = function(session, fun, ..., .timeout = 600) {
  remote_request(session, as.call(list(fun, ...)), .timeout)
}

remote_request = function(session, expr, timeout, call = rlang::caller_env()) {
  session$conn$write_message(serialize(expr, NULL), timeout = timeout)
  reply = session$conn$read_message(timeout = timeout)
  if (is.null(reply)) {
    cli::cli_abort("The host closed the connection.", call = call)
  }
  result = unserialize(reply)
  if (length(result$output) > 0) {
    cat(result$output, sep = "\n")
  }
  if (!is.null(result$error)) {
    cli::cli_abort(
      c("The code failed on the host.", "x" = "{result$error}"),
      class = "remote_error",
      call = call
    )
  }
  if (result$visible) result$value else invisible(result$value)
}

remote_close = function(session) {
  # Tell the host we are done, then give the shutdown time to reach it.
  session$conn$close_write()
  session$conn$close()
  session$client$close(drain = 5)
  invisible()
}

print.remote_session = function(x, ...) {
  state = if (x$conn$is_closed) "closed" else "connected"
  cat("<remote session, ", state, ">\n", sep = "")
  invisible(x)
}
