# Run the event loop from a script

Asynchronous results, `TailcatListener$serve()`, and
`TailcatConnection$read_loop()` only make progress while the later event
loop runs. At the console and inside Shiny that happens on its own; a
script run with `Rscript` has to run the loop itself. These functions do
that.

## Usage

``` r
tailcat_wait(promise, timeout = Inf)

tailcat_run(until = NULL, timeout = Inf)
```

## Arguments

- promise:

  A promise, or anything
  [`promises::is.promising()`](https://rstudio.github.io/promises/reference/is.promise.html)
  accepts.

- timeout:

  Seconds to wait; `Inf` (the default) waits indefinitely and `0` runs
  the callbacks that are already due, without waiting. When
  `tailcat_wait()` times out it raises a `tailcat_timeout` error; the
  operation behind the promise keeps going (cancel it with
  [`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md)
  if it should not).

- until:

  A function of no arguments that returns `TRUE` when the loop should
  stop, or `NULL`. It is called before each turn of the loop.

## Value

`tailcat_wait()` returns the promise's value. `tailcat_run()` returns,
invisibly, `TRUE` if `until()` returned `TRUE` and `FALSE` if the
timeout ran out.

## Details

`tailcat_wait()` runs the event loop until `promise` settles and returns
its value, or signals the condition it was rejected with, so a script
can use an `_async()` method like a blocking one. `tailcat_run()` runs
the event loop until `until()` returns `TRUE` or the timeout runs out;
with `until = NULL` it runs until the timeout runs out, which with the
default `timeout = Inf` keeps a server script serving until it is
interrupted.

Both run the current later loop
([`later::current_loop()`](https://later.r-lib.org/reference/create_loop.html))
and can be interrupted. Nothing else in the script runs meanwhile,
except what the event loop runs.

## Examples

``` r
if (FALSE) { # \dontrun{
cli = TailcatClient$new(address)
conn = tailcat_wait(cli$dial_async(8080), timeout = 30)

srv = TailcatServer$new()
lst = srv$listen(8080)
lst$serve(handler)
tailcat_run(until = function() lst$is_closed)
} # }
```
