# Building on rtailcat

rtailcat gives you TCP streams and UDP datagrams between two R processes
that can be anywhere, without accounts, port forwarding, or a VPN. That
is a low-level building block, so this vignette shows three small things
you might build with it, each written as if it were a little package of
its own:

1.  wormhole: send an R object or a file to someone else.
2.  remote: run R code on a machine behind a firewall, such as a lab
    workstation.
3.  progress: watch a long-running job report its progress, live, over
    UDP.

Each section first defines the functions and then shows them in use. The
usage code always runs in two R sessions, usually on two different
machines, and each code block is labeled with the machine it runs on.
The code is complete and runnable; the functions are also installed with
the package, and you can load them with

``` r

examples = system.file("examples", package = "rtailcat")
for (f in c("wormhole.R", "remote.R", "progress.R")) source(file.path(examples, f))
```

A tailcat address is a secret: anyone who has it can connect to the
server. The output below shortens addresses to forms such as
`tcAbC...xYz`, and where code needs an address you paste in the full one
that the other side printed. Public keys (`nodekey:...`) are not secret,
but they are shortened the same way.

The output shown was recorded by running the code against a local test
relay. It is not computed when the vignette is built, because that needs
two R sessions and a network connection.

## Sending messages over a stream

A TCP connection is a stream of bytes, not of messages. `$read()`
returns whatever has arrived, at most 64 KiB at a time, so one
`$write()` on one side can turn into several reads on the other, and two
writes can arrive in a single read. `$read_all()` collects everything up
to the end of the stream, which is enough when each side sends one thing
and then calls `$close_write()`. For a conversation with several
messages in each direction you need to mark where each message ends.

`$write_message()` and `$read_message()` do this for you. Each
`$read_message()` returns exactly what one `$write_message()` on the
other side sent, however the bytes were split up on the way. It returns
`NULL` when the other side has ended the stream between two messages,
which is how a reader learns that the other side is done. With
`max_bytes` it refuses a message larger than that before reading any of
it, so a peer cannot make you allocate an arbitrary amount of memory. On
the wire each message is its length as 4 bytes, big-endian, followed by
the bytes, so a program written in another language can take part in the
same conversation.

The examples below use messages for everything that goes over TCP. To
send an R object, send `serialize(x, NULL)` as a message and call
[`unserialize()`](https://rdrr.io/r/base/serialize.html) on the other
side.

## wormhole: sending an object or a file

Sharing a data set with a collaborator usually means email attachments,
a shared drive, or uploading it somewhere. With wormhole the sender runs
`wormhole_send()`, which prints an address and waits; the receiver runs
`wormhole_receive()` with that address and gets the object. Neither side
needs a public IP address or an open port, and the data is encrypted end
to end.

The sender starts a server, listens on a fixed port, and waits for one
connection. It sends a small JSON header describing the payload, then
the payload, and waits for the receiver to confirm before it shuts down.
Once the receiver has connected, the listener is closed, so nobody else
can connect with the same address.

``` r

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
```

The address is a `tailcat_secret`, which prints as `<redacted>`, so
`wormhole_offer()` calls
[`tailcat_reveal()`](https://rundel.github.io/rtailcat/reference/tailcat_reveal.md)
to show it deliberately. This is the one place the secret is meant to
appear.

Closing a server tears down its connections at once, so the receiver
might not see the end of the stream cleanly. Closing the connection
first and then calling `$close(drain = 5)` waits up to five seconds for
that shutdown to reach the other side before closing the server. The
receiver does the same with its client.

The receiver dials the sender, reads the header and checks the announced
size against its own limit, reads the payload, and only then confirms. A
file is written to `dir` under the name the sender gave, after checking
that the name cannot point anywhere else and that it would not overwrite
an existing file.

``` r

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
```

[`unserialize()`](https://rdrr.io/r/base/serialize.html) can run code
while it rebuilds an object, so use `wormhole_receive()` for objects
only from senders you trust. Here that is natural: the receiver connects
to an address that the sender gave them, so they already know who is on
the other end. Files are written as bytes and are not interpreted.

### Using it

The sender passes any R object to `wormhole_send()`, which waits until
the transfer is done.

``` r

library(rtailcat)
wormhole_send(mtcars)
#> Waiting for the receiver. Give them this address privately:
#>   tcAbC...xYz
#> Sent 3.8 kB.
```

The receiver pastes the address into `wormhole_receive()`:

``` r

library(rtailcat)
cars = wormhole_receive("tcAbC...xYz")
#> Receiving an R object (3.8 kB).
head(cars, 3)
#>                mpg cyl disp  hp drat    wt  qsec vs am gear carb
#> Mazda RX4     21.0   6  160 110 3.90 2.620 16.46  0  1    4    4
#> Mazda RX4 Wag 21.0   6  160 110 3.90 2.875 17.02  0  1    4    4
#> Datsun 710    22.8   4  108  93 3.85 2.320 18.61  1  1    4    1
```

Files work the same way. Each call starts a new server with a new
address, so an address that was used once is worthless afterwards.

``` r

write.csv(mtcars, "mtcars.csv")
wormhole_send_file("mtcars.csv")
#> Waiting for the receiver. Give them this address privately:
#>   tcDeF...uVw
#> Sent 1.8 kB.
```

``` r

path = wormhole_receive("tcDeF...uVw")
#> Receiving mtcars.csv (1.8 kB).
path
#> [1] "./mtcars.csv"
nrow(read.csv(path))
#> [1] 32
```

## remote: running R code on another machine

Suppose the data or the computing power you need sits on a workstation
in your lab or office, behind a firewall that does not let you in. With
remote, the workstation runs `remote_serve()`, and from anywhere you can
send it R code to evaluate and get the results back.

This is much more powerful than sending a file, and so it needs more
care. Anyone who can reach the server can run any R code on the host, so
the host should accept only the clients it knows. tailcat supports this
directly: each side can have a stable key pair, and a server given
`allowed_clients` accepts connections only from those public keys.
Stable keys also give the host a stable address, so the client can keep
using it across restarts of the server.

`tailcat_keygen(path)` creates a key pair the first time and saves it in
a file only you can read, and later calls load it from there. The file
contains the private key and pre-shared key, so treat it like an SSH
private key.

The host side accepts one connection at a time and handles requests on
it until the client disconnects. Each request is a message holding a
serialized R expression, evaluated in a fresh environment; the reply
carries the value, any printed output, and the error message if
evaluation failed.

``` r

remote_port = 4405L

remote_serve = function(keys, allowed_clients, max_bytes = 1e8) {
  srv = TailcatServer$new(key = keys, allowed_clients = allowed_clients)
  on.exit(srv$close(), add = TRUE)
  lst = srv$listen(remote_port)
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c("Serving R for {length(allowed_clients)} client{?s} at this address:", " " = "{address}"))
  repeat {
    conn = lst$accept()
    cli::cli_inform("Client connected.")
    tryCatch(
      remote_session(conn, max_bytes),
      error = function(e) cli::cli_inform(c("The connection failed:", "x" = "{conditionMessage(e)}"))
    )
    conn$close()
  }
}

remote_session = function(conn, max_bytes) {
  n = 0
  repeat {
    request = conn$read_message(max_bytes = max_bytes)
    if (is.null(request)) {
      break
    }
    reply = remote_run(unserialize(request))
    conn$write_message(serialize(reply, NULL), timeout = 600)
    n = n + 1
  }
  cli::cli_inform("Client disconnected after {n} request{?s}.")
}

remote_run = function(expr) {
  env = new.env(parent = globalenv())
  result = list(value = NULL, visible = FALSE, error = NULL)
  result$output = utils::capture.output(
    tryCatch(
      {
        res = withVisible(eval(expr, env))
        result$value = res$value
        result$visible = res$visible
      },
      error = function(e) result$error <<- conditionMessage(e)
    )
  )
  result
}
```

On the client, `remote_eval()` sends an expression as written, and
`remote_call()` sends a function together with arguments that are
evaluated locally first. Printed output from the host is shown locally,
and an error on the host becomes an error of class `remote_error`.

``` r

remote_connect = function(address, keys) {
  cl = TailcatClient$new(address, key = keys)
  conn = tryCatch(cl$dial(remote_port, timeout = 60), error = function(e) {
    cl$close()
    stop(e)
  })
  structure(list(client = cl, conn = conn), class = "remote_session")
}

remote_eval = function(session, expr, timeout = 600) {
  remote_request(session, substitute(expr), timeout)
}

remote_call = function(session, fun, ..., .timeout = 600) {
  remote_request(session, as.call(c(list(fun), list(...))), .timeout)
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
    cli::cli_abort(c("The code failed on the host.", "x" = "{result$error}"), class = "remote_error", call = call)
  }
  if (result$visible) result$value else invisible(result$value)
}

remote_close = function(session) {
  session$conn$close_write()
  session$conn$close()
  session$client$close(drain = 5)
  invisible()
}

print.remote_session = function(x, ...) {
  cat(if (x$conn$is_closed) "<remote session, closed>" else "<remote session, connected>", "\n")
  invisible(x)
}
```

A function sent with `remote_call()` is serialized with its environment.
A function defined at the top level of your session refers to the global
environment, which is not sent, so on the host it sees the host’s global
environment instead of your variables; pass what it needs as arguments.

### Using it

The client creates its keys once and gives its public key to whoever
runs the host. A public key is not a secret.

``` r

library(rtailcat)
keys = tailcat_keygen("~/.config/remote/client.json")
keys$public_key
#> [1] "nodekey:3f1c...9a0e"
```

The host does the same for itself and starts serving, allowing only that
client. `remote_serve()` runs until it is interrupted, so run it in a
dedicated R session, for example inside tmux or screen on the
workstation. Thanks to the stable keys, its address stays the same every
time it is restarted.

``` r

library(rtailcat)
keys = tailcat_keygen("~/.config/remote/host.json")
remote_serve(keys, allowed_clients = "nodekey:3f1c...9a0e")
#> Serving R for 1 client at this address:
#>   tcAbC...xYz
#> Client connected.
#> Warning: cannot open file 'no-such-file.csv': No such file or directory
#> Client disconnected after 5 requests.
```

The client connects with the host’s address and its own keys, then sends
code. Each call is one round trip over the same connection.

``` r

r = remote_connect("tcAbC...xYz", keys)
remote_eval(r, summary(lm(mpg ~ wt, data = mtcars))$r.squared)
#> [1] 0.7528328
remote_call(r, function(n) {
  set.seed(1)
  x = rowMeans(matrix(rexp(n * 10), ncol = 10))
  cat("Simulated", n, "means on the host\n")
  round(quantile(x, c(0.025, 0.975)), 3)
}, 1e6)
#> Simulated 1e+06 means on the host
#>  2.5% 97.5% 
#> 0.480 1.707 
remote_eval(r, assign("x", 1))
remote_eval(r, exists("x"))
#> [1] FALSE
```

The last two calls show that each request runs in a fresh environment:
`x` does not survive from one request to the next. Errors on the host
arrive as errors on the client, and the connection stays usable. Only
printed output and errors are sent back; warnings and messages stay on
the host, like the warning from
[`read.csv()`](https://rdrr.io/r/utils/read.table.html) in the host’s
output above.

``` r

remote_eval(r, read.csv("no-such-file.csv"))
#> Error in `remote_eval()`:
#> ! The code failed on the host.
#> ✖ cannot open the connection
remote_close(r)
```

A client whose key is not in `allowed_clients` cannot connect at all,
even with the right address: its `remote_connect()` runs out its
timeout. To allow another client while the host is running, call
`$allow_client()` on the server; here that would mean adding an argument
to `remote_serve()` or reading the allowed keys from a file.

`remote_serve()` handles one client at a time, and while it evaluates a
request it does nothing else. That is fine for one person using their
own workstation. Several users, or several requests in parallel, would
call for one worker process per connection, for example with callr or
mirai, but the protocol would stay the same.

## progress: watching a long-running job over UDP

A long simulation or model fit on a cluster node or a cloud machine
usually reports its progress to a log file, which you then have to go
and read. With progress, the job sends small progress reports to your
laptop as it runs, and your laptop collects them in the background,
while you keep using the R console, or shows them in a Shiny app.

This is a good fit for UDP. Each report is a single small datagram, and
if one is lost the next one is along shortly, so there is no point in
waiting for retransmissions or keeping a connection alive. More
importantly, sending a datagram never blocks the job for long and never
fails because the monitor has gone away: the job should not slow down,
or stop, because nobody is watching. Each datagram holds at most 1232
bytes, which is plenty for a few numbers encoded as JSON.

Note that the server runs on the laptop and the job is the client, the
reverse of what you might expect. The laptop prints an address and the
job dials it, so neither needs to accept connections from the internet.

The monitor listens on a UDP port and calls a handler for each flow, one
per job. The handler starts a read loop on the flow, which calls
`progress_record()` with each datagram as it arrives. Nothing blocks:
the reports are collected by the later event loop whenever the R console
is idle, or while Shiny is running.

``` r

progress_monitor = function(port = 9000L) {
  srv = TailcatServer$new()
  lst = srv$listen(port, network = "udp")
  monitor = new.env(parent = emptyenv())
  monitor$server = srv
  monitor$events = list()
  lst$serve(function(conn) {
    conn$read_loop(function(datagram) progress_record(monitor, datagram), on_error = function(e) NULL)
  })
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c("Collecting progress reports on UDP port {port}. Address for the jobs:", " " = "{address}"))
  structure(monitor, class = "progress_monitor")
}

progress_record = function(monitor, datagram) {
  event = tryCatch(jsonlite::fromJSON(rawToChar(datagram)), error = function(e) NULL)
  if (is.list(event)) {
    event$received = Sys.time()
    monitor$events[[length(monitor$events) + 1]] = event
  }
  invisible()
}

progress_data = function(monitor) {
  events = monitor$events
  if (length(events) == 0) {
    return(data.frame())
  }
  cols = unique(unlist(lapply(events, names)))
  rows = lapply(events, function(e) {
    e[setdiff(cols, names(e))] = NA
    as.data.frame(e[cols])
  })
  out = do.call(rbind, rows)
  out = out[order(out$job, out$seq), , drop = FALSE]
  rownames(out) = NULL
  out
}

progress_stop = function(monitor) {
  monitor$server$close()
  invisible()
}

print.progress_monitor = function(x, ...) {
  jobs = unique(vapply(x$events, function(e) e$job, character(1)))
  cat("<progress monitor>", length(x$events), "reports from", length(jobs), "jobs\n")
  invisible(x)
}
```

A report that is malformed, for example one sent by something other than
`progress_report()`, is ignored. Since a monitor accepts reports from
anyone who has its address, it does nothing with them other than store
them. If reading from a flow fails, the read loop closes it; the
`on_error` callback that does nothing keeps that from showing up as a
warning.

The job side dials the monitor once and then sends one datagram per
report. Each report carries the job name and a sequence number, so the
monitor can tell jobs apart and notice lost reports. `progress_report()`
never signals an error: if the monitor is unreachable the report is
simply lost, and a write that cannot complete within a second is
abandoned.

``` r

progress_reporter = function(address, job, port = 9000L) {
  cl = TailcatClient$new(address)
  reporter = new.env(parent = emptyenv())
  reporter$client = cl
  reporter$conn = cl$dial(port, network = "udp", timeout = 60)
  reporter$job = job
  reporter$seq = 0L
  reporter
}

progress_report = function(reporter, ...) {
  reporter$seq = reporter$seq + 1L
  event = list(job = reporter$job, seq = reporter$seq, sent = as.numeric(Sys.time()), ...)
  payload = charToRaw(jsonlite::toJSON(event, auto_unbox = TRUE, digits = NA))
  if (length(payload) > tailcat_udp_max_payload()) {
    cli::cli_warn("Report {reporter$seq} is {length(payload)} bytes, over the {tailcat_udp_max_payload()} bytes a datagram can hold, and was not sent.")
    return(invisible(FALSE))
  }
  sent = tryCatch(
    {
      reporter$conn$write(payload, timeout = 1)
      TRUE
    },
    error = function(e) FALSE
  )
  invisible(sent)
}

progress_done = function(reporter) {
  reporter$client$close()
  invisible()
}
```

Finally, a small Shiny app plots one metric against another, with a line
per job, and lists each job’s latest report. It checks for new reports
once a second. Shiny runs the later event loop, so the monitor keeps
collecting reports while the app is open.

``` r

progress_app = function(monitor, x = "iter", y = "loss") {
  ui = shiny::fluidPage(
    shiny::titlePanel("Job progress"),
    shiny::plotOutput("plot"),
    shiny::tableOutput("latest")
  )
  server = function(input, output, session) {
    data = shiny::reactivePoll(
      1000, session,
      checkFunc = function() length(monitor$events),
      valueFunc = function() progress_data(monitor)
    )
    output$plot = shiny::renderPlot({
      d = data()
      shiny::req(nrow(d) > 0, x %in% names(d), y %in% names(d))
      jobs = unique(d$job)
      plot(d[[x]], d[[y]], type = "n", xlab = x, ylab = y)
      for (i in seq_along(jobs)) {
        rows = d$job == jobs[i]
        lines(d[[x]][rows], d[[y]][rows], col = i, lwd = 2)
      }
      legend("topright", legend = jobs, col = seq_along(jobs), lwd = 2, bty = "n")
    })
    output$latest = shiny::renderTable({
      d = data()
      shiny::req(nrow(d) > 0)
      latest = d[!duplicated(d$job, fromLast = TRUE), setdiff(names(d), c("sent", "received")), drop = FALSE]
      latest$age = paste(round(as.double(Sys.time() - d$received[!duplicated(d$job, fromLast = TRUE)], units = "secs")), "s")
      latest
    })
  }
  shiny::shinyApp(ui, server)
}
```

### Using it

Start the monitor on your laptop. It returns at once and keeps
collecting in the background.

``` r

library(rtailcat)
m = progress_monitor()
#> Collecting progress reports on UDP port 9000. Address for the jobs:
#>   tcAbC...xYz
```

Give the job the address, for example through an environment variable,
or a file only you can read written with
`tailcat_address_write(m$server, path)` and read in the job with
`tailcat_address_read(path)`, and call `progress_report()` wherever the
job has something to say. Here a loop that shrinks a number stands in
for the real work.

``` r

library(rtailcat)
reporter = progress_reporter("tcAbC...xYz", job = "fit-1")
loss = 1
for (i in 1:20) {
  Sys.sleep(0.1)
  loss = loss * 0.8
  progress_report(reporter, iter = i, loss = loss)
}
progress_done(reporter)
```

Back on the laptop the reports have arrived. Missing sequence numbers
would show lost reports.

``` r

m
#> <progress monitor> 20 reports from 1 jobs
d = progress_data(m)
tail(d[c("job", "seq", "iter", "loss")], 3)
#>      job seq iter       loss
#> 18 fit-1  18   18 0.01801440
#> 19 fit-1  19   19 0.01441152
#> 20 fit-1  20   20 0.01152922
setdiff(seq_len(max(d$seq)), d$seq)
#> integer(0)
```

While jobs are running, `progress_app()` shows their progress live. Any
number of jobs can report to one monitor, each under its own name.

``` r

shiny::runApp(progress_app(m))
```

``` r

progress_stop(m)
```

The monitor’s address changes every time it starts. To keep one address
for all your jobs, create keys once with `tailcat_keygen(path)`, which
saves them securely and loads them on later calls, and pass them to
`TailcatServer$new(key = keys)` in `progress_monitor()`, as
`remote_serve()` does.

In an R script run with `Rscript`, rather than at the console, nothing
runs the event loop while the script waits, so call
[`tailcat_run()`](https://rundel.github.io/rtailcat/reference/tailcat_wait.md)
to keep collecting reports, for example `tailcat_run(timeout = 3600)`
for an hour.
