# Tailcat server

A tailcat server registers with a public relay and publishes a secret,
shareable address. Clients holding the address can dial the ports the
server listens on, over TCP or UDP, without accounts or port forwarding.

Blocking methods have an `_async()` counterpart that returns a
[`promises::promise()`](https://rstudio.github.io/promises/reference/promise.html)
resolving with the same value, or rejecting with the same condition.
Asynchronous results are delivered by the later event loop, so they only
arrive while R is idle at the console, inside Shiny or httpuv, or while
you call
[`later::run_now()`](https://later.r-lib.org/reference/run_now.html).
The result goes to the loop that was current when the operation started,
so an operation started inside
[`later::with_temp_loop()`](https://later.r-lib.org/reference/create_loop.html)
or
[`later::with_loop()`](https://later.r-lib.org/reference/create_loop.html)
completes while that loop runs. If that loop is destroyed before the
operation completes, the result is delivered on the global loop instead
(checked about once a second while such operations are pending). A
pending asynchronous operation can be canceled with
[`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md).

Blocking methods can be interrupted (Ctrl-C or Esc), which cancels the
operation. If the operation completes at the same moment, its result is
returned and that interrupt is dropped rather than losing data such as
bytes just read.

The address and the private and pre-shared keys are secrets: anyone with
the address can connect. Printing a server never shows them. `$address`
and the `address` element of `$info()` are
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
strings, which print as `<redacted>` but otherwise behave like the full
address (for example with
[`writeLines()`](https://rdrr.io/r/base/writeLines.html) or
[`as.character()`](https://rdrr.io/r/base/character.html)). The server
does not keep the address in an R field, so saving the server object
(for example with [`saveRDS()`](https://rdrr.io/r/base/readRDS.html) or
[`save.image()`](https://rdrr.io/r/base/save.html)) does not write the
address to disk. Handles do not survive serialization: a server restored
from a saved session is closed.

Once a server is closed, every method other than `$close()`,
`$format()`, and `$print()`, and every field other than `$is_closed`,
raises a `tailcat_closed` error; nothing is kept from before.

## Timeouts

Every blocking method and function of this package takes a `timeout` in
seconds. `Inf` waits indefinitely. `timeout = 0` is a non-blocking poll:
the call returns what is available right away (for example data already
received, or a connection already waiting) and otherwise raises
`tailcat_timeout` at once. This differs from tailcat's C ABI
([tailcat.h](https://github.com/tailscale/tailcat/blob/e00cdde6ff787f801361ff85ed085775c775d4c5/cmd/libtailcat/tailcat.h)),
where a zero timeout is an already expired deadline that fails without
trying; rtailcat gives a poll a deadline of a few milliseconds instead.
A poll waits for an operation started before it in the same direction of
a connection only for that short time.

A timeout ends only that call: the server, listener, client, or
connection stays usable.

## Errors

Errors are conditions with class `tailcat_error` and one subclass that
says what went wrong. Each also carries an integer `status` (the status
code of the C ABI) and `bytes`, the number of bytes transferred before
the error (for reads and writes; otherwise `0`). The message starts with
a one-line summary; a line starting `tailcat:` gives tailcat's own
description when it has one.

|  |  |  |
|----|----|----|
| `status` | Class | Meaning |
| 1 | `tailcat_invalid_argument` | An argument is invalid |
| 2 | `tailcat_closed` | The object, or the client or server that owns it, is closed |
| 3 | `tailcat_timeout` | The timeout ran out |
| 4 | `tailcat_canceled` | The operation was canceled with [`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md) |
| 5 | `tailcat_failure` | Anything else, including calls made in the wrong state |

Branch on the class (for example with
`tryCatch(..., tailcat_timeout = function(e) ...)`) or the `status`, not
on the message, whose wording may change.

## Operations in flight

Every operation that can block (each method or function with a
`timeout`, and fields such as `$address` that ask tailcat), synchronous
or asynchronous, holds its own operating system thread from the moment
it starts until it ends, including while it waits its turn behind other
reads or writes on a connection. The option `rtailcat.max_operations`
caps how many such operations may be in flight in the R process at once.
It must be a single positive whole number, or `Inf` for no cap, and
defaults to 1024, which stays well below the per-process thread limits
of macOS (about 6,000) and typical Linux systems and the 10,000 threads
at which the Go runtime ends the process. The option is read each time
an operation starts. An operation started when the cap is reached fails
at once with a `tailcat_failure` error that names the option and gives
the limit, without affecting the operations already in flight; once some
of them finish or are canceled, new operations work again. If the option
is set to an invalid value, every such operation fails with a
`tailcat_failure` error saying so.

## Relay options

The relay used by servers and clients can be set once for the R session
with options, instead of passing the same arguments to every `$new()`
(including calls inside other packages' code). The option
`rtailcat.region` is used by `TailcatServer$new()` when `region` is
`NULL`, and `rtailcat.derp_map_url` by `TailcatServer$new()`,
`TailcatClient$new()`, and
[`tailcat_address_resolve()`](https://rundel.github.io/rtailcat/reference/tailcat_address_resolve.md)
when `derp_map_url` is `NULL`. They take the same values as the
arguments, are read when the object is created, and are ignored when
unset (`NULL`, the default). An argument given explicitly always wins;
to go back to the default relays, unset the option.

For example, a deployment that runs its own relay region can call
`options(rtailcat.region = region)` at startup, and one that publishes
its own relay map `options(rtailcat.derp_map_url = url)`.

## Active bindings

- `address`:

  The secret tailcat address to give to clients, as a
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md).
  It is fetched from tailcat on each access (a quick local call) rather
  than stored in R. Errors if the server has not started.

- `public_key`:

  The server's public key, or `NA` before the server has started.

- `is_started`:

  `TRUE` once the server has started (registered with the relay),
  `FALSE` before.

- `is_closed`:

  `TRUE` once the server has been closed.

## Methods

### Public methods

- [`TailcatServer$new()`](#method-TailcatServer-initialize)

- [`TailcatServer$start()`](#method-TailcatServer-start)

- [`TailcatServer$start_async()`](#method-TailcatServer-start_async)

- [`TailcatServer$listen()`](#method-TailcatServer-listen)

- [`TailcatServer$listen_async()`](#method-TailcatServer-listen_async)

- [`TailcatServer$allow_client()`](#method-TailcatServer-allow_client)

- [`TailcatServer$allow_client_async()`](#method-TailcatServer-allow_client_async)

- [`TailcatServer$info()`](#method-TailcatServer-info)

- [`TailcatServer$info_async()`](#method-TailcatServer-info_async)

- [`TailcatServer$drain()`](#method-TailcatServer-drain)

- [`TailcatServer$drain_async()`](#method-TailcatServer-drain_async)

- [`TailcatServer$close()`](#method-TailcatServer-close)

- [`TailcatServer$format()`](#method-TailcatServer-format)

- [`TailcatServer$print()`](#method-TailcatServer-print)

------------------------------------------------------------------------

### `TailcatServer$new()`

Create a server. Nothing is sent over the network until the server is
started (by `$start()` or `$listen()`). Only arguments that are not
`NULL` are passed to tailcat.

#### Usage

    TailcatServer$new(
      key = NULL,
      preshared_key = NULL,
      region_id = NULL,
      region = NULL,
      derp_map_url = NULL,
      allowed_clients = NULL,
      udp_idle_timeout = NULL
    )

#### Arguments

- `key`:

  Private node key: a string in tailcat's text encoding, a
  `tailcat_keys` object from
  [`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md),
  or `NULL` to generate one. A `tailcat_keys` object also supplies the
  pre-shared key, unless `preshared_key` is given. Keep the keys to
  reuse an address across restarts.

- `preshared_key`:

  Pre-shared key (text encoding), or `NULL` to generate one (or take it
  from `key`).

- `region_id`:

  Integer relay region to register in, or `NULL` to choose
  automatically.

- `region`:

  A relay region definition, as a list or a JSON string, to use instead
  of the public relay map, or `NULL` to use the `rtailcat.region` option
  (see the section on relay options) or, when that is unset, the public
  relays. Field names may be the snake_case names used by
  [`tailcat_address_parse()`](https://rundel.github.io/rtailcat/reference/tailcat_address_parse.md)
  (`region_id`, `region_code`, `nodes`, and within each node `name`,
  `host_name`, `ipv4`, `relay_port`, and so on) or the PascalCase names
  of Tailscale's `DERPRegion` type (`RegionID`, `Nodes`, `HostName`,
  `DERPPort`, and so on).

- `derp_map_url`:

  URL of a relay map to use instead of the default, or `NULL` to use the
  `rtailcat.derp_map_url` option (see the section on relay options in
  TailcatServer) or, when that is unset, the default.

- `allowed_clients`:

  Character vector of client public keys. If given, only these clients
  may connect; otherwise anyone with the address may.

- `udp_idle_timeout`:

  Seconds after which an idle UDP flow is dropped, or `NULL` for the
  default.

------------------------------------------------------------------------

### `TailcatServer$start()`

Register with the relay so the server has an address. Calling it again
is harmless.

#### Usage

    TailcatServer$start(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls (see the
  section on timeouts).

#### Returns

The server, invisibly.

------------------------------------------------------------------------

### `TailcatServer$start_async()`

Asynchronous version of `$start()`.

#### Usage

    TailcatServer$start_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the server.

------------------------------------------------------------------------

### `TailcatServer$listen()`

Listen on a port, starting the server first if needed.

#### Usage

    TailcatServer$listen(port = 0L, network = c("tcp", "udp"), timeout = 30)

#### Arguments

- `port`:

  Port number; `0` picks a free port (see the listener's `$port`).

- `network`:

  Exactly `"tcp"` (the default) or `"udp"`.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A
[TailcatListener](https://rundel.github.io/rtailcat/reference/TailcatListener.md).

------------------------------------------------------------------------

### `TailcatServer$listen_async()`

Asynchronous version of `$listen()`.

#### Usage

    TailcatServer$listen_async(port = 0L, network = c("tcp", "udp"), timeout = 30)

#### Arguments

- `port`:

  Port number; `0` picks a free port.

- `network`:

  Exactly `"tcp"` (the default) or `"udp"`.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with a
[TailcatListener](https://rundel.github.io/rtailcat/reference/TailcatListener.md).

------------------------------------------------------------------------

### `TailcatServer$allow_client()`

Add a client public key to the allowlist. Once the list has an entry,
only listed clients can register; existing connections are not affected.

#### Usage

    TailcatServer$allow_client(public_key, timeout = 30)

#### Arguments

- `public_key`:

  A client public key, for example `TailcatClient$public_key`.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

The server, invisibly.

------------------------------------------------------------------------

### `TailcatServer$allow_client_async()`

Asynchronous version of `$allow_client()`.

#### Usage

    TailcatServer$allow_client_async(public_key, timeout = 30)

#### Arguments

- `public_key`:

  A client public key.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the server.

------------------------------------------------------------------------

### `TailcatServer$info()`

Information about the started server.

#### Usage

    TailcatServer$info(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A list of class `tailcat_info` (so that
[`format()`](https://rdrr.io/r/base/format.html) redacts the address in
every version of R) with `address` (a
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)),
`ip` (the server's own IP address on the tailcat network, without a
port), and `public_key`. Errors if the server has not started.

------------------------------------------------------------------------

### `TailcatServer$info_async()`

Asynchronous version of `$info()`.

#### Usage

    TailcatServer$info_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the info list.

------------------------------------------------------------------------

### `TailcatServer$drain()`

Wait for TCP shutdown traffic to finish. Call it after closing
connections and before closing the server or exiting R, so that peers
see a clean end of stream.

#### Usage

    TailcatServer$drain(timeout = 5)

#### Arguments

- `timeout`:

  Seconds to wait. `Inf` is accepted but waits as long as shutdown
  takes, which can be indefinitely when a peer has gone away, so a
  finite value is recommended.

#### Returns

The server, invisibly.

------------------------------------------------------------------------

### `TailcatServer$drain_async()`

Asynchronous version of `$drain()`.

#### Usage

    TailcatServer$drain_async(timeout = 5)

#### Arguments

- `timeout`:

  Seconds to wait; as for `$drain()`, a finite value is recommended.

#### Returns

A promise resolving with the server.

------------------------------------------------------------------------

### `TailcatServer$close()`

Close the server, its listeners, and all of its connections. Pending
operations on them end with a `tailcat_closed` error. Closing twice is
harmless. Closing tears the server down immediately, so clients may not
see the end of their streams until their own reads time out. To give
clients a clean end of stream, close the connections first and pass
`drain`, which waits for their shutdown traffic before closing (see
`$drain()`).

#### Usage

    TailcatServer$close(drain = 0)

#### Arguments

- `drain`:

  Seconds to wait for TCP shutdown traffic before closing, as for
  `$drain()`; `0` (the default) closes at once. A drain that times out
  or fails does not prevent the close and is not reported.

#### Returns

The server, invisibly.

------------------------------------------------------------------------

### `TailcatServer$format()`

Format a summary, the lines that `$print()` shows. The address and keys
are never shown. A closed server shows only its state.

#### Usage

    TailcatServer$format(...)

#### Arguments

- `...`:

  Ignored.

#### Returns

A character vector.

------------------------------------------------------------------------

### `TailcatServer$print()`

Print the summary from `$format()`.

#### Usage

    TailcatServer$print(...)

#### Arguments

- `...`:

  Ignored.

## Examples

``` r
if (FALSE) { # \dontrun{
srv = TailcatServer$new()
lst = srv$listen(8080)
srv$address # share this with the client, it is a secret
conn = lst$accept()
conn$read()
srv$close()
} # }
```
