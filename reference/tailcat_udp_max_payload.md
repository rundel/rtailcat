# Largest UDP datagram

The largest payload, in bytes, that one UDP datagram can carry over
tailcat. `TailcatConnection$write()` on a UDP connection raises a
`tailcat_invalid_argument` error for larger data, so check the size
first when the data varies.

## Usage

``` r
tailcat_udp_max_payload()
```

## Value

`1232L`.

## Examples

``` r
payload = charToRaw("progress: 50%")
length(payload) <= tailcat_udp_max_payload()
#> [1] TRUE
```
