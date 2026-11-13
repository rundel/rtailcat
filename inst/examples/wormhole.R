# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R
# Edit the vignette, not this file

wormhole_port = 4404L

format_bytes = function(n) {
  # Formats a byte count for messages, such as "3.8 kB"

  structure(n, class = "object_size") |>
    format(units = "auto", standard = "SI")
}

wormhole_send = function(x, timeout = 600) {
  # Sends an R object to one receiver and waits until it confirms

  srv = TailcatServer$new()
  on.exit(srv$close(), add = TRUE)
  lst = srv$listen(wormhole_port)
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c(
    "Waiting for the receiver. Give them this address privately:",
    "{address}"
  ))

  conn = lst$accept(timeout = timeout)

  # One transfer per address: nobody else can connect once the receiver has
  lst$close()

  # The protocol: the serialized object, then "ok" from the receiver
  payload = serialize(x, NULL)
  conn$write_message(payload, timeout = timeout)

  # The reply is "ok", so a longer one is refused without reading it
  reply = conn$read_message(timeout = timeout, as = "text", max_bytes = 16)
  if (!identical(reply, "ok")) {
    cli::cli_abort("The receiver did not confirm the transfer.")
  }
  conn$close()
  srv$close(drain = 5)
  cli::cli_inform("Sent {format_bytes(length(payload))}.")
  invisible(TRUE)
}

wormhole_receive = function(address, max_bytes = 1e9, timeout = 600) {
  # Receives one R object from the sender at `address` and returns it

  cl = TailcatClient$new(address)
  on.exit(cl$close(), add = TRUE)
  conn = cl$dial(wormhole_port, timeout = 60)

  payload = conn$read_message(timeout = timeout, max_bytes = max_bytes)
  if (is.null(payload)) {
    cli::cli_abort("The sender closed the connection without sending anything.")
  }

  # unserialize() can run code, which is acceptable only because the receiver
  # dialed an address the sender gave them and so knows who is sending
  value = unserialize(payload)
  cli::cli_inform("Received {format_bytes(length(payload))}.")

  conn$write_message("ok", timeout = 60)
  conn$close_write()
  conn$close()
  cl$close(drain = 5)
  value
}
