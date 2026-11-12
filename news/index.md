# Changelog

## rtailcat 0.0.0.9000

Initial version, embedding tailcat’s Go library through its C ABI
(version 1).

### Features

- R6 classes for both ends of a tailcat connection: `TailcatServer`
  (registers with a relay and publishes a secret address),
  `TailcatListener` (accepts TCP connections or UDP flows on a port),
  `TailcatClient` (dials a server by its address), and
  `TailcatConnection` (reads, writes, half-close, and connection info).
- Every blocking method has an `_async()` twin that returns a promise
  settled on the later event loop current at the call, and
  `TailcatListener$serve()` runs an accept loop that hands each
  connection to a handler. Pending asynchronous operations can be
  canceled with
  [`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md),
  and blocking calls can be interrupted without losing data that has
  already arrived.
- Reads and writes on one connection run in the order they were started,
  while a read and a write can run at the same time. `$read_all()` and
  `$read_all_async()` read to the end of a TCP stream, optionally
  limited by `max_bytes`.
- Errors are conditions of class `tailcat_error` with one subclass per C
  ABI status (`tailcat_invalid_argument`, `tailcat_closed`,
  `tailcat_timeout`, `tailcat_canceled`, `tailcat_failure`), carrying
  the `status` and the `bytes` transferred.
- Addresses, private keys, and pre-shared keys are `tailcat_secret`
  strings that print and format as `<redacted>`;
  [`format()`](https://rdrr.io/r/base/format.html) and
  [`print()`](https://rdrr.io/r/base/print.html) of the R6 objects never
  show them.
  [`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
  creates keys for a stable server address or client identity,
  `allowed_clients` and `$allow_client()` restrict who may connect, and
  [`tailcat_address_parse()`](https://rundel.github.io/rtailcat/reference/tailcat_address_parse.md),
  [`tailcat_address_resolve()`](https://rundel.github.io/rtailcat/reference/tailcat_address_resolve.md),
  and
  [`tailcat_build_info()`](https://rundel.github.io/rtailcat/reference/tailcat_build_info.md)
  inspect addresses and the embedded library.
- The option `rtailcat.max_operations` (default 1024) caps the number of
  operations in flight, each of which holds an operating system thread.

### Departures from the C ABI

- `timeout = 0` is a non-blocking poll (data already received, a
  connection already waiting) rather than an already expired deadline.
- `TailcatClient$ping()` returns seconds rather than milliseconds, like
  `$disco_ping()` and the timeouts.
- Field names in the results of `$info()`, `$disco_ping()`, and
  [`tailcat_address_parse()`](https://rundel.github.io/rtailcat/reference/tailcat_address_parse.md)
  are snake_case (`relay_port`, `relay_region_id`, and so on) instead of
  tailcat’s JSON names; `tailcat_build_info()$raw` keeps Go’s own names.

### Known upstream issues

- On a UDP connection `$read(n = 0)` fails with `tailcat_failure` and
  discards the waiting datagram.
- On a TCP connection whose two directions have both been shut down
  (both sides called `$close_write()`), `$info()`, `$local_address`, and
  `$remote_address` fail with `tailcat_failure` and tailcat prints a Go
  stack trace. Printing such a connection leaves the endpoints out
  instead.
