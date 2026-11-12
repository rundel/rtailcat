# Embed relay details in a tailcat address

Returns a self-contained version of `address` with the relay (DERP)
details embedded, fetching the relay map if needed. A resolved address
avoids relay map discovery when a client connects, although connecting
still needs network access. The result is a secret, like the input.

## Usage

``` r
tailcat_address_resolve(address, derp_map_url = NULL, timeout = 30)

tailcat_address_resolve_async(address, derp_map_url = NULL, timeout = 30)
```

## Arguments

- address:

  A tailcat address, as a string or the
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  returned by `TailcatServer$address`. Surrounding whitespace is
  ignored. Addresses are secrets.

- derp_map_url:

  URL of a relay map to use instead of the default, or `NULL`.

- timeout:

  Seconds to wait; `Inf` waits indefinitely and `0` polls (see the
  section on timeouts in
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md)).

## Value

`tailcat_address_resolve()` returns the resolved address as a
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md).
`tailcat_address_resolve_async()` returns a
[`promises::promise()`](https://rstudio.github.io/promises/reference/promise.html)
that resolves with it.
