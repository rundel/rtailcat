# rtailcat

<!-- badges: start -->
[![R-CMD-check](https://github.com/rundel/rtailcat/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/rundel/rtailcat/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

rtailcat lets R act as either end of a [tailcat](https://github.com/tailscale/tailcat) connection. A tailcat server registers with a public relay and gets a secret, shareable address; any client holding that address can open TCP streams or exchange UDP datagrams with the server, from anywhere, without accounts, port forwarding, or a VPN. Traffic is end-to-end encrypted and uses a direct path between the peers when one can be found.

The package embeds tailcat's Go library through its versioned C ABI and wraps it in R6 classes: `TailcatServer`, `TailcatListener`, `TailcatClient`, and `TailcatConnection`. Every blocking method also has an `_async()` version that returns a [promises](https://rstudio.github.io/promises/) promise, so servers can run alongside Shiny, httpuv, or other code driven by the [later](https://r-lib.github.io/later/) event loop.

## Installation

Building the package needs a Go toolchain (version 1.27.2 or newer, see `src/go/go.mod`), a C compiler, and GNU make. `configure` looks for Go in the `RTAILCAT_GO` environment variable, on the `PATH`, and in a few common install locations, and fails with an explanation if it cannot find a recent enough version. It never downloads Go itself.

The first build downloads the pinned, checksum-verified Go modules unless the source tree contains `src/go/vendor/` (created by `tools/vendor.sh`), in which case it builds offline. A tarball built from a vendored tree is meant for offline or self-contained installs, not for CRAN: the vendored Go sources include file paths longer than 100 bytes, so `R CMD build` warns that such paths are not portable to every tar implementation. The warning is expected and does not affect installing with a current R.

Install the development version from GitHub with [pak](https://pak.r-lib.org/), which builds the package from source, so Go must be installed as described above:

```r
pak::pak("rundel/rtailcat")
```

Or, from a checkout of the source:

```sh
R CMD INSTALL rtailcat
```

## A server and a client

Run the server in one R session. It listens on port 8080 of its tailcat address and writes the address to a file that only you can read; give that file to the client by any private channel.

```r
library(rtailcat)

srv = TailcatServer$new()
lst = srv$listen(8080)
writeLines(srv$address, "address.txt")
Sys.chmod("address.txt", "600")

conn = lst$accept()
msg = conn$read_all(as = "text")
conn$write(paste0("server received: ", msg))
conn$close_write()
conn$close()

srv$drain()
srv$close()
```

Run the client in a second R session, on the same machine or anywhere else:

```r
library(rtailcat)

cl = TailcatClient$new(readLines("address.txt"))
conn = cl$dial(8080)
conn$write("hello from the client")
conn$close_write()
conn$read_all(as = "text")
#> [1] "server received: hello from the client"
conn$close()

cl$drain()
cl$close()
```

Reads return raw vectors by default; `as = "text"` returns a UTF-8 string instead. Over TCP a single `$read()` can end in the middle of a multibyte character, so use `$read_all(as = "text")`, or read raw bytes and convert them once, for multibyte text. Data containing NUL bytes cannot be read as text and raises an error.

`$read_all()` keeps the whole stream in memory, so give it a limit when the peer is not trusted: `conn$read_all(max_bytes = 1e6)` raises a `tailcat_failure` error as soon as the stream turns out to be longer than a million bytes. The bytes read are discarded, but the connection stays open.

`$close_write()` tells the other side that you have finished sending (it then reads end of stream, so `$read_all()` returns), while still letting you read the reply. `$drain()` waits briefly for TCP shutdown traffic to finish so the peer sees a clean close; call it before closing a client or server or quitting R.

Use `network = "udp"` in `$listen()` and `$dial()` for datagrams: each `$write()` sends one datagram of at most 1232 bytes and each `$read()` returns one. A UDP flow appears at the listener once the client has sent its first datagram.

A few helpers round this out: `cl$ping()` and `cl$disco_ping()` measure latency to the server in seconds (the latter also reports whether the path is direct or through a relay), `tailcat_address_parse()` shows the public parts of an address without revealing its pre-shared key, and `tailcat_build_info()` reports the embedded tailcat and Go versions.

## Serving connections asynchronously

`$serve()` runs an accept loop on the later event loop and calls a handler for each connection, without blocking the R session. This echo server handles any number of clients, one after another or at the same time:

```r
library(rtailcat)

srv = TailcatServer$new()
lst = srv$listen(7)
lst$serve(function(conn) {
  promises::then(conn$read_all_async(timeout = 60), function(data) {
    conn$write(data)
    conn$close_write()
    conn$close()
  })
})
writeLines(srv$address, "address.txt")
Sys.chmod("address.txt", "600")
```

The loop only makes progress while the event loop runs, which happens automatically when the R console is idle and inside Shiny or httpuv apps. In a script run with `Rscript`, keep it running explicitly:

```r
while (!lst$is_closed) later::run_now(Inf)
```

A handler error, or a rejection of the promise the handler returns (as in the example above), is passed to `on_error` if you give one (`lst$serve(handler, on_error = function(cond, conn) ...)`), otherwise it becomes a warning; either way that connection is closed and the loop carries on. Closing the listener or the server ends the loop; `lst$stop_serving()` ends it but keeps the listener open. Blocking calls inside a handler hold up the event loop until they return, so prefer the `_async()` methods there.

The other asynchronous methods work the same way, for example `cl$dial_async(8080)` or `srv$listen_async(0)`. Promises reject with the same error conditions the blocking methods raise. Reads, and writes, on one connection run in the order they are started, so several `$write_async()` calls send their data in call order, while a read and a write can run at the same time. A promise is settled on the later event loop that was current when the operation started, for example inside `later::with_temp_loop()`; if that loop is destroyed first, the result is delivered on the global loop instead.

Any promise returned by an `_async()` method or function can be canceled with `tailcat_cancel()`. The promise then rejects with a `tailcat_canceled` condition, and the listener, connection, client, or server stays usable, as after a timeout:

```r
pending = lst$accept_async()
# ... later, nobody came
tailcat_cancel(pending)
promises::catch(pending, function(e) {
  if (inherits(e, "tailcat_canceled")) message("accept canceled")
})
```

Cancel the promise returned by the `_async()` call itself: promises derived from it with `promises::then()` or a promise pipe do not carry the cancellation handle. Canceling an operation that has already finished, or canceling twice, does nothing. For `$read_all_async()` the read in flight is canceled and no further reads start.

## Errors and timeouts

Timeouts are in seconds and `Inf` means no limit. Starting, listening, dialing, pinging, and resolving default to 30 seconds, draining to 5, and accepting, reading, and writing wait indefinitely. A timeout only ends that call: the listener or connection stays usable.

`timeout = 0` is a non-blocking poll: `conn$read(timeout = 0)` returns data that has already arrived, `lst$accept(timeout = 0)` returns a connection that is already waiting, and otherwise they raise `tailcat_timeout` at once. This differs from tailcat's C ABI, where a zero timeout is an already expired deadline; see the Timeouts section of `?TailcatServer`.

Errors are conditions of class `tailcat_error` with one subclass, and they carry the integer `status` and, for reads and writes, the number of `bytes` transferred before the error:

| `status` | Class                      | Meaning                                                     |
| -------- | -------------------------- | ----------------------------------------------------------- |
| 1        | `tailcat_invalid_argument` | An argument is invalid                                      |
| 2        | `tailcat_closed`           | The object, or the client or server that owns it, is closed |
| 3        | `tailcat_timeout`          | The timeout ran out                                         |
| 4        | `tailcat_canceled`         | The operation was canceled with `tailcat_cancel()`          |
| 5        | `tailcat_failure`          | Anything else, including calls made in the wrong state      |

Branch on the class or the status rather than on the message:

```r
tryCatch(
  lst$accept(timeout = 5),
  tailcat_timeout = function(e) message("nobody connected")
)
```

The message starts with a one-line summary, followed by tailcat's own description when it has one:

```
Error in `lst$accept()`:
! Timed out after 5 seconds trying to accept a connection.
ℹ tailcat: context deadline exceeded
```

Once a server, client, listener, or connection is closed (or the client or server that owns it is), its methods and fields raise `tailcat_closed`; only `$close()`, `$format()`, `$print()`, and `$is_closed` keep working, as do a listener's `$server` and a connection's `$client` or `$server`, which give the object that owns it. Objects restored from a saved session (`saveRDS()`, a saved workspace) are closed, because the handles inside them do not survive serialization.

Blocking calls can be interrupted with Ctrl-C or Esc. If the operation completes at the same moment as the interrupt (for example a read whose data has just arrived), its result is returned and that interrupt is dropped, so no data is lost; press again to interrupt the code that follows.

## Security

A tailcat address is a credential. It contains the server's public key, relay details, and a pre-shared key, and anyone who has it can connect to every port the server listens on. Share it privately and do not commit it, log it, or paste it into chats or issues. Addresses, private keys, and pre-shared keys are returned as `tailcat_secret` strings: `print()`, `format()`, and `str()` show `<redacted>`, as do `print()` and `str()` of lists that contain them (and `format()` of such lists from R 4.6.0), while `writeLines()`, `paste()`, `as.character()`, and the functions of this package use the full value. `dput()`, `saveRDS()`, and explicit conversions reveal the value, so store secrets deliberately. Servers fetch their address from tailcat when asked instead of keeping it in R, so saving a server object does not write its address to disk.

By default each server gets a new key pair and address. To keep an address across restarts, create the keys once with `tailcat_keygen()`, store them securely, and pass them back with `TailcatServer$new(key = keys)`, which uses both the private key and the pre-shared key. To accept only particular clients, give them stable keys (`TailcatClient$new(address, key = keys)`) and list their public keys in `allowed_clients` or add them with `$allow_client()`.

## Caveats

- The package embeds a Go runtime in the R process. It cannot be unloaded, so the package's shared object stays loaded until R exits.
- The Go runtime does not survive `fork()`. rtailcat refuses to run in a forked child process, which includes the workers of `parallel::mclapply()` and `parallel::mcparallel()`, and the `multicore` backend of future. Use separate R processes (for example `parallel::makePSOCKcluster()`, callr, or mirai) instead.
- Asynchronous results, including `$serve()` handlers, are only delivered while the later event loop runs.
- Each operation in flight that can block (every method or function with a `timeout`, and fields such as `$address` that ask tailcat), synchronous or asynchronous, running or waiting its turn on a connection, uses its own operating system thread. The option `rtailcat.max_operations` caps how many may be in flight at once in the R process: a positive whole number, or `Inf` for no cap, read each time an operation starts. The default of 1024 stays well below the per-process thread limits of macOS (about 6,000) and typical Linux systems and the 10,000 threads at which the Go runtime ends the process. An operation started at the cap fails at once with a `tailcat_failure` error that names the option and the limit; the operations already in flight are not affected. See the section on operations in flight in `?TailcatServer`.
- One `$read()` returns at most 65536 bytes, whatever `n` is; loop, or use `$read_all()`, to read more.
- Two bugs in the pinned tailcat version show through, and rtailcat does not work around them. `$read(n = 0)` on a UDP connection fails and discards the waiting datagram. `$info()`, `$local_address`, and `$remote_address` on a TCP connection fail (and tailcat prints a Go stack trace) once both sides have called `$close_write()`; read them before shutting the connection down. Printing a connection shows its endpoints only until `$close_write()` succeeds on it, so printing never triggers this.

## Platform status

| Platform             | Status                         |
| -------------------- | ------------------------------ |
| macOS (arm64)        | Tested                         |
| macOS (x86_64)       | Expected to work, untested     |
| Linux                | Expected to work, untested     |
| Windows (Rtools)     | Build files provided, untested |

## Development

`devtools::test()` runs the end-to-end tests against a local relay on 127.0.0.1, so they need Go but no internet access: a setup file builds upstream's `internal/capitest` relay from the small Go module in `tests/relay/` (pinned to the same tailcat commit as the package) into a temporary directory and stops it when the run ends. If the relay cannot be built or started, the tests fall back to tailcat's public relays and say so. Set `RTAILCAT_TEST_RELAY` to `local` (fail instead of falling back), `public`, or `auto` (the default), or `RTAILCAT_SKIP_ONLINE=1` to skip the network tests. On CRAN, and under `R CMD check` unless `NOT_CRAN=true`, nothing is built and the network tests are skipped.

## License

rtailcat is BSD 3-clause licensed. It statically links tailcat and its Go dependencies, copyright Tailscale Inc and contributors and others; see `inst/COPYRIGHTS` for the full list of bundled components and their licenses.
