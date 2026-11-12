# Tailcat listener

A listener accepts TCP connections or UDP flows on one port of a
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).
Listeners are created by `TailcatServer$listen()`, not directly.

Accepted connections belong to the server rather than the listener:
closing the listener stops new connections but leaves accepted ones
open, while closing the server closes everything.

Once the listener or its server is closed, every method other than
`$close()`, `$stop_serving()`, `$format()`, and `$print()`, and every
field other than `$is_closed` and `$server`, raises a `tailcat_closed`
error. Timeouts (including `timeout = 0`, a poll) and errors are
described in
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).

## Serving connections

`$serve(handler)` starts an accept loop driven by the later event loop
and returns immediately. Each new connection is passed to
`handler(conn)` on the main R thread. The loop only makes progress while
the event loop runs: when R is idle at the console, inside Shiny or
httpuv, or while a script calls
[`later::run_now()`](https://later.r-lib.org/reference/run_now.html) in
a loop. Blocking calls inside the handler (such as `conn$read()`) hold
up the loop until they return, so long-running handlers should use the
`_async()` methods and return the resulting promise. A handler may
return a promise (or anything
[`promises::is.promising()`](https://rstudio.github.io/promises/reference/is.promise.html)
accepts): if it rejects, the rejection is treated like an error signaled
by the handler, so `on_error` is called and the connection is closed.
The loop does not wait for the promise before accepting the next
connection. The loop ends quietly when the listener or the server is
closed, or when `$stop_serving()` is called; `$stop_serving()` leaves
the listener open, so it can accept connections again or serve with a
new handler.

## Active bindings

- `port`:

  The port number being listened on.

- `local_address`:

  The local endpoint as `"host:port"` on the server's tailcat network
  (not the secret tailcat address).

- `network`:

  `"tcp"` or `"udp"`.

- `server`:

  The owning
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).

- `is_closed`:

  `TRUE` once the listener or its server has been closed.

## Methods

### Public methods

- [`TailcatListener$new()`](#method-TailcatListener-initialize)

- [`TailcatListener$accept()`](#method-TailcatListener-accept)

- [`TailcatListener$accept_async()`](#method-TailcatListener-accept_async)

- [`TailcatListener$serve()`](#method-TailcatListener-serve)

- [`TailcatListener$stop_serving()`](#method-TailcatListener-stop_serving)

- [`TailcatListener$info()`](#method-TailcatListener-info)

- [`TailcatListener$info_async()`](#method-TailcatListener-info_async)

- [`TailcatListener$close()`](#method-TailcatListener-close)

- [`TailcatListener$format()`](#method-TailcatListener-format)

- [`TailcatListener$print()`](#method-TailcatListener-print)

------------------------------------------------------------------------

### `TailcatListener$new()`

Internal constructor; use `TailcatServer$listen()`.

#### Usage

    TailcatListener$new(handle, server, network)

#### Arguments

- `handle`:

  Native listener handle.

- `server`:

  The owning
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md).

- `network`:

  Integer network code.

------------------------------------------------------------------------

### `TailcatListener$accept()`

Wait for the next connection (TCP) or new flow (UDP). A timeout ends
only this call; the listener stays usable.

#### Usage

    TailcatListener$accept(timeout = Inf)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls (returns a
  connection that is already waiting).

#### Returns

A
[TailcatConnection](https://rundel.github.io/rtailcat/reference/TailcatConnection.md).

------------------------------------------------------------------------

### `TailcatListener$accept_async()`

Asynchronous version of `$accept()`.

#### Usage

    TailcatListener$accept_async(timeout = Inf)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with a
[TailcatConnection](https://rundel.github.io/rtailcat/reference/TailcatConnection.md).

------------------------------------------------------------------------

### `TailcatListener$serve()`

Start an asynchronous accept loop that calls `handler(conn)` for every
connection. See the section on serving connections.

#### Usage

    TailcatListener$serve(handler, on_error = NULL)

#### Arguments

- `handler`:

  A function of one argument, the
  [TailcatConnection](https://rundel.github.io/rtailcat/reference/TailcatConnection.md).
  It may return a promise.

- `on_error`:

  A function `function(cond, conn)` called when `handler` signals an
  error or the promise it returned rejects (or when accepting fails,
  with `conn = NULL`), or `NULL` to turn such errors into warnings
  (signaled from the later event loop). After a handler error the
  connection is closed. An error signaled by `on_error` itself is turned
  into a warning.

#### Returns

The listener, invisibly. Calling it on a listener that is already
serving raises a `tailcat_failure` error (call `$stop_serving()` first),
and on a closed listener a `tailcat_closed` error.

------------------------------------------------------------------------

### `TailcatListener$stop_serving()`

Stop the accept loop started by `$serve()` without closing the listener.
The pending accept is canceled; connections already accepted are not
affected, and a connection whose accept completed at the same moment is
still passed to the handler. Calling it when the listener is not serving
does nothing.

#### Usage

    TailcatListener$stop_serving()

#### Returns

The listener, invisibly.

------------------------------------------------------------------------

### `TailcatListener$info()`

Information about the listener.

#### Usage

    TailcatListener$info(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A list with `local_address` and `network`.

------------------------------------------------------------------------

### `TailcatListener$info_async()`

Asynchronous version of `$info()`.

#### Usage

    TailcatListener$info_async(timeout = 30)

#### Arguments

- `timeout`:

  Seconds to wait; `Inf` waits indefinitely and `0` polls.

#### Returns

A promise resolving with the info list.

------------------------------------------------------------------------

### `TailcatListener$close()`

Stop accepting connections. Accepted connections stay open. Closing
twice is harmless.

#### Usage

    TailcatListener$close()

#### Returns

The listener, invisibly.

------------------------------------------------------------------------

### `TailcatListener$format()`

Format a summary, the lines that `$print()` shows.

#### Usage

    TailcatListener$format(...)

#### Arguments

- `...`:

  Ignored.

#### Returns

A character vector.

------------------------------------------------------------------------

### `TailcatListener$print()`

Print the summary from `$format()`.

#### Usage

    TailcatListener$print(...)

#### Arguments

- `...`:

  Ignored.

## Examples

``` r
if (FALSE) { # \dontrun{
srv = TailcatServer$new()
lst = srv$listen(7)
lst$serve(function(conn) {
  promises::then(conn$read_all_async(timeout = 30), function(data) {
    conn$write(data)
    conn$close()
  })
})
srv$address
} # }
```
