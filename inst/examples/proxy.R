# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R
# Edit the vignette, not this file

proxy_port = 4406L

proxy_send = function(conn, head, body) {
  # Sends one request or response: a JSON head, then the body as its own message

  head$headers = I(head$headers)
  head |>
    jsonlite::toJSON(auto_unbox = TRUE) |>
    conn$write_message(timeout = 60)
  conn$write_message(body, timeout = 60)
}

proxy_receive = function(conn, max_bytes) {
  # Reads one request or response sent with proxy_send(), or NULL if the other side closed the
  # connection first

  head = conn$read_message(timeout = 60, as = "text", max_bytes = 65536)
  if (is.null(head)) {
    return(NULL)
  }
  head = jsonlite::fromJSON(head)
  head$headers = as.character(unlist(head$headers))
  head$body = conn$read_message(timeout = 60, max_bytes = max_bytes)
  head
}

proxy_drop_headers = c(
  "connection", "keep-alive", "transfer-encoding", "content-length", "host", "upgrade",
  "accept-encoding", "content-encoding"
)

proxy_clean_headers = function(lines) {
  # Drops the headers that each side's HTTP library sets for itself

  names = lines |> sub(pattern = ":.*", replacement = "") |> tolower()
  lines[!names %in% proxy_drop_headers]
}

proxy_header_list = function(lines) {
  # Turns "Name: value" lines into the named list that curl and httpuv take

  values = sub("^[^:]*:[[:space:]]*", "", lines)
  stats::setNames(as.list(values), sub(":.*", "", lines))
}

proxy_error = function(e) {
  # A 502 response saying why the proxy could not get an answer

  list(
    status = 502L,
    headers = "Content-Type: text/plain; charset=utf-8",
    body = charToRaw(paste("The proxy could not reach the app:", conditionMessage(e)))
  )
}

proxy_forward = function(request, app_port) {
  # Replays a request against the app on this machine and returns the app's response

  # The path comes from the other side; a path that does not start with "/", such as
  # "@example.com/", would change the host the request goes to
  if (!startsWith(request$path, "/")) {
    stop("The request path must start with \"/\".")
  }
  handle = curl::new_handle(customrequest = request$method, followlocation = FALSE)
  curl::handle_setheaders(handle, .list = proxy_header_list(request$headers))
  if (length(request$body) > 0) {
    curl::handle_setopt(handle, copypostfields = request$body)
  }
  url = paste0("http://127.0.0.1:", app_port, request$path)
  res = curl::curl_fetch_memory(url, handle = handle)
  headers = curl::parse_headers(res$headers)[-1]
  list(status = res$status_code, headers = proxy_clean_headers(headers), body = res$content)
}

proxy_answer = function(conn, app_port, max_bytes) {
  # Answers one request that arrived on `conn` and closes the connection

  on.exit(conn$close())
  request = proxy_receive(conn, max_bytes)
  if (is.null(request)) {
    return(invisible())
  }
  response = tryCatch(proxy_forward(request, app_port), error = proxy_error)
  proxy_send(conn, response[c("status", "headers")], response$body)
}

proxy_share = function(app_port, max_bytes = 1e8) {
  # Makes the app listening on `app_port` of this machine reachable through a new address

  srv = TailcatServer$new()
  lst = srv$listen(proxy_port)
  lst$serve(\(conn) proxy_answer(conn, app_port, max_bytes))
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c(
    "Sharing the app on port {app_port}. Address for the other machine:",
    "{address}"
  ))
  invisible(srv)
}

proxy_fetch = function(cl, req) {
  # Sends one request from httpuv to the other machine and returns the response for httpuv

  request = list(
    method = req$REQUEST_METHOD,
    path = paste0(req$PATH_INFO, req$QUERY_STRING),
    headers = proxy_clean_headers(paste0(names(req$HEADERS), ": ", req$HEADERS))
  )
  body = req$rook.input$read()
  response = tryCatch(
    {
      conn = cl$dial(proxy_port, timeout = 30)
      on.exit(conn$close())
      proxy_send(conn, request, body)
      response = proxy_receive(conn, max_bytes = Inf)
      if (is.null(response)) {
        stop("The other side closed the connection.")
      }
      response
    },
    error = proxy_error
  )
  list(
    status = as.integer(response$status),
    headers = proxy_header_list(response$headers),
    body = response$body
  )
}

proxy_open = function(address, port = 8080L) {
  # Serves the app shared at `address` on http://127.0.0.1:`port` of this machine

  cl = TailcatClient$new(address)
  server = httpuv::startServer("127.0.0.1", port, list(call = \(req) proxy_fetch(cl, req)))
  cli::cli_inform("Open {.url http://127.0.0.1:{port}} to use the app on the other machine.")
  structure(list(client = cl, server = server), class = "proxy")
}

proxy_close = function(proxy) {
  # Stops the local server and disconnects from the other machine

  httpuv::stopServer(proxy$server)
  proxy$client$close()
  invisible()
}
