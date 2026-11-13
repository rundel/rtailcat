# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R; edit the vignette, not this file.

wormhole_port = 4404L

wormhole_send = function(x, timeout = 600) {
  wormhole_offer(list(kind = "object"), serialize(x, NULL), timeout)
}

wormhole_send_file = function(path, timeout = 600) {
  payload = readBin(path, "raw", n = file.size(path))
  wormhole_offer(list(kind = "file", name = basename(path)), payload, timeout)
}

wormhole_offer = function(header, payload, timeout) {
  srv = TailcatServer$new()
  on.exit(srv$close(), add = TRUE)
  lst = srv$listen(wormhole_port)
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c("Waiting for the receiver. Give them this address privately:", " " = "{address}"))

  conn = lst$accept(timeout = timeout)
  lst$close()
  header$size = length(payload)
  conn$write_message(jsonlite::toJSON(header, auto_unbox = TRUE), timeout = 60)
  conn$write_message(payload, timeout = timeout)
  reply = conn$read_message(timeout = timeout, as = "text", max_bytes = 16)
  if (!identical(reply, "ok")) {
    cli::cli_abort("The receiver did not confirm the transfer.")
  }
  conn$close()
  srv$close(drain = 5)
  cli::cli_inform("Sent {format_bytes(length(payload))}.")
  invisible(TRUE)
}

format_bytes = function(n) {
  format(structure(n, class = "object_size"), units = "auto", standard = "SI")
}

wormhole_receive = function(address, dir = ".", max_bytes = 1e9, timeout = 600) {
  cl = TailcatClient$new(address)
  on.exit(cl$close(), add = TRUE)
  conn = cl$dial(wormhole_port, timeout = 60)
  header = conn$read_message(timeout = timeout, as = "text", max_bytes = 4096)
  if (is.null(header)) {
    cli::cli_abort("The sender closed the connection without sending anything.")
  }
  header = jsonlite::fromJSON(header)
  if (header$size > max_bytes) {
    cli::cli_abort("The sender offered {format_bytes(header$size)}, more than {.arg max_bytes} allows.")
  }
  what = if (header$kind == "file") header$name else "an R object"
  cli::cli_inform("Receiving {what} ({format_bytes(header$size)}).")
  payload = conn$read_message(timeout = timeout, max_bytes = header$size)
  if (is.null(payload)) {
    cli::cli_abort("The sender closed the connection before sending the data.")
  }

  value = if (header$kind == "file") wormhole_save(payload, header$name, dir) else unserialize(payload)
  conn$write_message("ok", timeout = 60)
  conn$close_write()
  conn$close()
  cl$close(drain = 5)
  value
}

wormhole_save = function(payload, name, dir) {
  if (!is.character(name) || length(name) != 1 || !nzchar(name) || name != basename(name) || name %in% c(".", "..")) {
    cli::cli_abort("The sender offered an unsafe file name.")
  }
  path = file.path(dir, name)
  if (file.exists(path)) {
    cli::cli_abort("{.path {path}} already exists.")
  }
  writeBin(payload, path)
  path
}
