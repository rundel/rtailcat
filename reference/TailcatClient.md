# Tailcat client

A tailcat client connects to the
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md)
identified by a secret tailcat address. It can only dial that server.
Network startup happens on the first `$dial()`, `$ping()`, or
`$disco_ping()`.

Blocking methods have an `_async()` counterpart that returns a
[`promises::promise()`](https://rstudio.github.io/promises/reference/promise.html);
see
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md)
for how asynchronous results are delivered, for timeouts (including
`timeout = 0`), and for the error classes.

The address is a secret; printing a client never shows it or the private
key, and the client does not keep a copy of the address in R.

Once a client is closed, every method other than `$close()`,
`$format()`, and `$print()`, and every field other than `$is_closed`,
raises a `tailcat_closed` error; nothing is kept from before. A client
restored from a saved session is closed, because handles do not survive
serialization.

A server with an allowlist (`allowed_clients` or
`TailcatServer$allow_client()`) does not answer clients that are not on
it, so for such a client `$dial()`, `$ping()`, and `$disco_ping()` fail
with `tailcat_timeout` once their timeout runs out, rather than with a
distinct error.

## Active bindings

- `public_key`:

  The client's public key, for `TailcatServer$allow_client()`. It is
  fetched from tailcat on each access.

- `is_closed`:

  `TRUE` once the client has been closed.

## Methods

### Public methods

- [`TailcatClient$new()`](#method-TailcatClient-initialize)

- [`TailcatClient$dial()`](#method-TailcatClient-dial)

- [`TailcatClient$dial_async()`](#method-TailcatClient-dial_async)

- [`TailcatClient$ping()`](#method-TailcatClient-ping)

- [`TailcatClient$ping_async()`](#method-TailcatClient-ping_async)

- [`TailcatClient$disco_ping()`](#method-TailcatClient-disco_ping)

- [`TailcatClient$disco_ping_async()`](#method-TailcatClient-disco_ping_async)

- [`TailcatClient$info()`](#method-TailcatClient-info)

- [`TailcatClient$info_async()`](#method-TailcatClient-info_async)

- [`TailcatClient$drain()`](#method-TailcatClient-drain)

- [`TailcatClient$drain_async()`](#method-TailcatClient-drain_async)

- [`TailcatClient$close()`](#method-TailcatClient-close)

- [`TailcatClient$format()`](#method-TailcatClient-format)

- [`TailcatClient$print()`](#method-TailcatClient-print)

------------------------------------------------------------------------

### `TailcatClient$new()`

Create a client. No network access happens until it is used.

#### Usage

    TailcatClient$new(address, key = NULL, derp_map_url = NULL)

#### Arguments

- `address`:

  The server's secret tailcat address (a string or a
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)).
  Surrounding whitespace, such as a trailing newline from a file, is
  ignored.

- `key`:

  Private node key (a string in text encoding, or a `tailcat_keys`
  object from
  [`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)),
  or `NULL` to generate one. A stable key gives the client a stable
  public key, for use with `allowed_clients`.

- `derp_map_url`:

  URL of a relay map to use instead of the default.

------------------------------------------------------------------------

### `TailcatClient$dial()`

Connect to a port on the server.

#### Usage

    TailcatClient$dial(port, network = c("tcp", "udp"), timeout = 30)

#### Arguments

- `port`:

  Port number (1 to 65535).

- `network`:

  Exactly `"tcp"` (the default) or `"udp"`.

- `timeout`:

  Seconds to wait, covering relay registration and the connection; `Inf`
  waits indefinitely and `0` polls.

#### Returns

A
[TailcatConnection](https://rundel.github.io/rtailcat/reference/TailcatConnection.md).

------------------------------------------------------------------------

### `TailcatClient$dial_async()`

Asynchronous version of `$dial()`.

#### Usage

    TailcatClient$dial_async(port, network = c("tcp", "udp"), timeout = 30)

#### Arguments

- `port`:

  Port number (1 to 65535).

- `network`:

  Exactly `"tcp"` (the default) or `"udp"`.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with a
[TailcatConnection](https://rundel.github.io/rtailcat/reference/TailcatConnection.md).

------------------------------------------------------------------------

### `TailcatClient$ping()`

Measure the round-trip time to the server through the relay.

#### Usage

    TailcatClient$ping(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

The latency in seconds (a double). tailcat reports whole milliseconds,
so the resolution is 0.001 and a ping faster than a millisecond reads as
`0`. This differs from tailcat's C ABI
([tailcat.h](https://github.com/tailscale/tailcat/blob/e00cdde6ff787f801361ff85ed085775c775d4c5/cmd/libtailcat/tailcat.h)),
which returns the milliseconds; seconds match `$disco_ping()` and the
timeouts.

------------------------------------------------------------------------

### `TailcatClient$ping_async()`

Asynchronous version of `$ping()`.

#### Usage

    TailcatClient$ping_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the latency in seconds.

------------------------------------------------------------------------

### `TailcatClient$disco_ping()`

Send a discovery ping, which also triggers direct path discovery.

#### Usage

    TailcatClient$disco_ping(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; use a finite value since discovery may otherwise wait
  indefinitely.

#### Returns

A list with `latency` (seconds), `endpoint` (the direct path, or `""`
when relayed), `relay_region_id`, and `relay_region_code` (the relay
region the ping went through).

------------------------------------------------------------------------

### `TailcatClient$disco_ping_async()`

Asynchronous version of `$disco_ping()`.

#### Usage

    TailcatClient$disco_ping_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait.

#### Returns

A promise resolving with the discovery ping list.

------------------------------------------------------------------------

### `TailcatClient$info()`

Information about the client.

#### Usage

    TailcatClient$info(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A list with `public_key`.

------------------------------------------------------------------------

### `TailcatClient$info_async()`

Asynchronous version of `$info()`.

#### Usage

    TailcatClient$info_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the info list.

------------------------------------------------------------------------

### `TailcatClient$drain()`

Wait for TCP shutdown traffic to finish. Call it after closing
connections (or reaching end of stream) and before closing the client or
exiting R, so the server sees a clean end of stream.

#### Usage

    TailcatClient$drain(timeout = 5)

#### Arguments

- `timeout`:

  Seconds to wait. `Inf` is accepted but waits as long as shutdown
  takes, which can be indefinitely when a peer has gone away, so a
  finite value is recommended.

#### Returns

The client, invisibly.

------------------------------------------------------------------------

### `TailcatClient$drain_async()`

Asynchronous version of `$drain()`.

#### Usage

    TailcatClient$drain_async(timeout = 5)

#### Arguments

- `timeout`:

  Seconds to wait; as for `$drain()`, a finite value is recommended.

#### Returns

A promise resolving with the client.

------------------------------------------------------------------------

### `TailcatClient$close()`

Close the client and all of its connections. Closing twice is harmless.
Closing tears the client down immediately, so the server may not see the
end of its streams until its own reads time out; to give the server a
clean end of stream, close the connections and call `$drain()` first.

#### Usage

    TailcatClient$close()

#### Returns

The client, invisibly.

------------------------------------------------------------------------

### `TailcatClient$format()`

Format a summary, the lines that `$print()` shows. The address and
private key are never shown. A closed client shows only its state.

#### Usage

    TailcatClient$format(...)

#### Arguments

- `...`:

  Ignored.

#### Returns

A character vector.

------------------------------------------------------------------------

### `TailcatClient$print()`

Print the summary from `$format()`.

#### Usage

    TailcatClient$print(...)

#### Arguments

- `...`:

  Ignored.

## Examples

``` r
if (FALSE) { # \dontrun{
address = readLines("address.txt")
cli = TailcatClient$new(address)
conn = cli$dial(8080)
conn$write("hello\n")
conn$close()
cli$drain()
cli$close()
} # }
```
