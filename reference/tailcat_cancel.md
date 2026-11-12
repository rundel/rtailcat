# Cancel a pending asynchronous operation

Cancels the operation behind a promise returned by any `_async()` method
or function in this package. The promise then rejects with a condition
of class `tailcat_canceled` (and `tailcat_error`). Cancellation only
ends that operation: the connection, listener, client, or server stays
usable, as after a timeout.

## Usage

``` r
tailcat_cancel(promise)
```

## Arguments

- promise:

  A promise returned by an `_async()` method or function of this
  package.

## Value

`promise`, invisibly.

## Details

Cancellation is delivered through the later event loop, like the
operation's result, so the promise rejects once the event loop runs. If
the operation had already finished, or finishes at the same moment,
canceling does nothing and the promise keeps (or receives) its result.
Canceling more than once is harmless.

For `TailcatConnection$read_all_async()`, which reads in several steps,
canceling ends the read in flight and no further reads are started; the
condition's `bytes` field gives the number of bytes read before it,
which are discarded.

Only the promise returned by the `_async()` call can be canceled. A
promise derived from it, for example with
[`promises::then()`](https://rstudio.github.io/promises/reference/then.html)
or `%...>%`, does not carry the cancellation handle, so keep a reference
to the original promise.

## Examples

``` r
if (FALSE) { # \dontrun{
srv = TailcatServer$new()
lst = srv$listen(8080)
pending = lst$accept_async()
tailcat_cancel(pending)
promises::catch(pending, function(e) message(class(e)[1]))
} # }
```
