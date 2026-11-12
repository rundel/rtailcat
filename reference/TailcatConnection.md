# Tailcat connection

A TCP stream or connected UDP flow between a
[TailcatClient](https://rundel.github.io/rtailcat/reference/TailcatClient.md)
and a
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).
Connections are created by `TailcatClient$dial()` and
`TailcatListener$accept()`, not directly.

For TCP, reads may return fewer bytes than requested and `$read()`
returns `NULL` at end of stream. For UDP, each read returns one datagram
(possibly `raw(0)`) and each write sends one datagram of at most 1232
bytes.

One read and one write may be in flight at the same time (for example a
pending `$read_async()` while writing). Further operations in the same
direction wait their turn and run in the order they were started, for
synchronous and asynchronous calls alike, so several `$write_async()`
calls send their data in call order and several `$read_async()` calls
receive consecutive chunks of the stream in call order. The wait counts
toward each operation's timeout, and canceling or timing out an
operation that is still waiting ends it without affecting the others.

`$client` or `$server` (the other is `NULL`) gives the object that owns
the connection, the client that dialed it or the server whose listener
accepted it.

Once the connection, or the client or server that owns it, is closed,
every method other than `$close()`, `$format()`, and `$print()`, and
every field other than `$is_closed`, `$client`, and `$server`, raises a
`tailcat_closed` error; nothing is kept from before. Timeouts (including
`timeout = 0`, a poll) and errors are described in
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).

Because of an upstream tailcat bug, `$info()` (and so `$local_address`
and `$remote_address`) fails with `tailcat_failure`, and the Go runtime
prints a stack trace to standard error, on a TCP connection whose two
directions have both been shut down (both sides called
`$close_write()`). `$print()` and `$format()` avoid this by leaving the
endpoints out once `$close_write()` has succeeded on the connection.

## Active bindings

- `local_address`:

  The local endpoint as `"host:port"` on the tailcat network. It is
  fetched from tailcat on each access.

- `remote_address`:

  The peer's endpoint as `"host:port"` on the tailcat network. It is
  fetched from tailcat on each access.

- `network`:

  `"tcp"` or `"udp"`.

- `client`:

  The
  [TailcatClient](https://rundel.github.io/rtailcat/reference/TailcatClient.md)
  that dialed the connection, or `NULL` for an accepted connection. Like
  `$server`, it keeps working after the connection is closed.

- `server`:

  The
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md)
  whose listener accepted the connection, or `NULL` for a dialed
  connection. It keeps working after the connection is closed.

- `is_closed`:

  `TRUE` once the connection, or the client or server that owns it, has
  been closed.

## Methods

### Public methods

- [`TailcatConnection$new()`](#method-TailcatConnection-initialize)

- [`TailcatConnection$read()`](#method-TailcatConnection-read)

- [`TailcatConnection$read_async()`](#method-TailcatConnection-read_async)

- [`TailcatConnection$read_all()`](#method-TailcatConnection-read_all)

- [`TailcatConnection$read_all_async()`](#method-TailcatConnection-read_all_async)

- [`TailcatConnection$write()`](#method-TailcatConnection-write)

- [`TailcatConnection$write_async()`](#method-TailcatConnection-write_async)

- [`TailcatConnection$close_write()`](#method-TailcatConnection-close_write)

- [`TailcatConnection$close_write_async()`](#method-TailcatConnection-close_write_async)

- [`TailcatConnection$readable()`](#method-TailcatConnection-readable)

- [`TailcatConnection$info()`](#method-TailcatConnection-info)

- [`TailcatConnection$info_async()`](#method-TailcatConnection-info_async)

- [`TailcatConnection$close()`](#method-TailcatConnection-close)

- [`TailcatConnection$format()`](#method-TailcatConnection-format)

- [`TailcatConnection$print()`](#method-TailcatConnection-print)

------------------------------------------------------------------------

### `TailcatConnection$new()`

Internal constructor; use `TailcatClient$dial()` or
`TailcatListener$accept()`.

#### Usage

    TailcatConnection$new(handle, owner, network)

#### Arguments

- `handle`:

  Native connection handle.

- `owner`:

  The owning
  [TailcatClient](https://rundel.github.io/rtailcat/reference/TailcatClient.md)
  or
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).

- `network`:

  Integer network code.

------------------------------------------------------------------------

### `TailcatConnection$read()`

Read up to `n` bytes (TCP) or one datagram (UDP, truncated to `n`
bytes). One call returns at most 65536 bytes whatever the value of `n`
(TCP reads may return less than requested anyway, and UDP datagrams are
much smaller), so loop, or use `$read_all()`, to read more. A timeout
ends only this read; the connection stays usable. With `timeout = 0` the
read returns data (or the end of stream) that has already arrived, and
otherwise raises `tailcat_timeout` at once. A TCP read returns whatever
has arrived, so with `as = "text"` a multibyte UTF-8 character can be
split across two reads; for multibyte text use `$read_all()`, or read
raw bytes and convert them once. On UDP, `n = 0` is not supported:
because of an upstream tailcat bug it fails and the datagram is lost.

#### Usage

    TailcatConnection$read(n = 65536L, timeout = Inf, as = c("raw", "text"))

#### Arguments

- `n`:

  Maximum number of bytes to return (at most 65536 are returned).

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

- `as`:

  Exactly `"raw"` (the default) to return a raw vector, or `"text"` to
  return a single string marked as UTF-8 (the bytes are not checked for
  valid UTF-8). Data containing NUL bytes cannot be returned as text and
  raises a `tailcat_invalid_argument` error; the data is consumed, so
  read binary data with `as = "raw"`.

#### Returns

A raw vector or a string, or `NULL` at TCP end of stream.

------------------------------------------------------------------------

### `TailcatConnection$read_async()`

Asynchronous version of `$read()`.

#### Usage

    TailcatConnection$read_async(n = 65536L, timeout = Inf, as = c("raw", "text"))

#### Arguments

- `n`:

  Maximum number of bytes to return.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

- `as`:

  `"raw"` or `"text"`, as for `$read()`.

#### Returns

A promise resolving with a raw vector or a string, or `NULL` at TCP end
of stream.

------------------------------------------------------------------------

### `TailcatConnection$read_all()`

Read until the peer ends the stream (TCP only). On timeout or error the
condition's `bytes` field gives the number of bytes read before it;
those bytes are discarded. With `timeout = 0` it returns only if the
whole stream, including its end, has already arrived.

#### Usage

    TailcatConnection$read_all(
      timeout = Inf,
      as = c("raw", "text"),
      max_bytes = Inf
    )

#### Arguments

- `timeout`:

  Overall seconds to wait; `Inf` waits indefinitely and `0` polls.

- `as`:

  Exactly `"raw"` (the default) to return a raw vector, or `"text"` to
  return a single string marked as UTF-8 (`""` for an empty stream). See
  `$read()` for NUL bytes.

- `max_bytes`:

  The most bytes to accept, a single non-negative whole number or `Inf`
  (the default) for no limit. If the stream is longer, reading stops
  after `max_bytes + 1` bytes and a `tailcat_failure` error is raised
  whose `bytes` field is the number of bytes read (`max_bytes + 1`).
  Those bytes are discarded, but the connection stays open and usable:
  the rest of the stream can still be read, or the connection closed.

#### Returns

A raw vector or a string.

------------------------------------------------------------------------

### `TailcatConnection$read_all_async()`

Asynchronous version of `$read_all()`. Canceling the promise with
[`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md)
ends the read in flight and starts no further reads.

#### Usage

    TailcatConnection$read_all_async(
      timeout = Inf,
      as = c("raw", "text"),
      max_bytes = Inf
    )

#### Arguments

- `timeout`:

  Overall seconds to wait; `Inf` waits indefinitely and `0` polls.

- `as`:

  `"raw"` or `"text"`, as for `$read_all()`.

- `max_bytes`:

  The most bytes to accept, as for `$read_all()`; a longer stream
  rejects the promise with a `tailcat_failure` error.

#### Returns

A promise resolving with a raw vector or a string.

------------------------------------------------------------------------

### `TailcatConnection$write()`

Write all of `data`. On timeout or error the condition's `bytes` field
gives the number of bytes already sent.

#### Usage

    TailcatConnection$write(data, timeout = Inf)

#### Arguments

- `data`:

  A raw vector, or a character vector which is pasted together without
  separators and sent as UTF-8.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls (sends what
  can be sent at once).

#### Returns

The number of bytes written (an integer, or a double beyond the integer
range), invisibly.

------------------------------------------------------------------------

### `TailcatConnection$write_async()`

Asynchronous version of `$write()`.

#### Usage

    TailcatConnection$write_async(data, timeout = Inf)

#### Arguments

- `data`:

  A raw or character vector.

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the number of bytes written.

------------------------------------------------------------------------

### `TailcatConnection$close_write()`

Half-close a TCP connection: tell the peer there is nothing more to
send, while still being able to read its reply.

#### Usage

    TailcatConnection$close_write(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait for pending writes; `Inf` waits indefinitely and `0`
  polls.

#### Returns

The connection, invisibly.

------------------------------------------------------------------------

### `TailcatConnection$close_write_async()`

Asynchronous version of `$close_write()`.

#### Usage

    TailcatConnection$close_write_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the connection.

------------------------------------------------------------------------

### `TailcatConnection$readable()`

Check without waiting whether a TCP read would return immediately
(buffered data, end of stream, or a pending error). Intended for
checking idle connections, not as a readiness loop.

#### Usage

    TailcatConnection$readable()

#### Returns

`TRUE` or `FALSE`.

------------------------------------------------------------------------

### `TailcatConnection$info()`

Information about the connection. Because of an upstream tailcat bug it
fails with `tailcat_failure` once both directions of a TCP connection
have been shut down.

#### Usage

    TailcatConnection$info(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A list with `local_address`, `remote_address`, and `network`.

------------------------------------------------------------------------

### `TailcatConnection$info_async()`

Asynchronous version of `$info()`.

#### Usage

    TailcatConnection$info_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the info list.

------------------------------------------------------------------------

### `TailcatConnection$close()`

Close the connection. Pending reads and writes end with a
`tailcat_closed` error. Closing twice is harmless.

#### Usage

    TailcatConnection$close()

#### Returns

The connection, invisibly.

------------------------------------------------------------------------

### `TailcatConnection$format()`

Format a summary, the lines that `$print()` shows. An open connection
shows its local and remote endpoints on the tailcat network (not
secrets); they are left out when the connection is closed, when tailcat
cannot report them, and once `$close_write()` has succeeded on it,
because asking tailcat after both sides have shut down their writes
triggers an upstream bug that prints a Go stack trace.

#### Usage

    TailcatConnection$format(...)

#### Arguments

- `...`:

  Ignored.

#### Returns

A character vector.

------------------------------------------------------------------------

### `TailcatConnection$print()`

Print the summary from `$format()`.

#### Usage

    TailcatConnection$print(...)

#### Arguments

- `...`:

  Ignored.

## Examples

``` r
if (FALSE) { # \dontrun{
conn = TailcatClient$new(address)$dial(8080)
conn$write("ping")
conn$close_write()
conn$read_all(timeout = 10, as = "text")
} # }
```
