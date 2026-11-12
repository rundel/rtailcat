# Generate tailcat keys

Generates a node key pair and a random pre-shared key locally, without
network access. Pass the result as the `key` of a
[TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md)
to give a server a stable identity and address across restarts, or pass
it as the `key` of a
[TailcatClient](https://rundel.github.io/rtailcat/reference/TailcatClient.md)
to give a client a stable public key (useful with `allowed_clients`).

## Usage

``` r
tailcat_keygen()
```

## Value

A list of class `tailcat_keys` with elements `private_key`,
`public_key`, and `preshared_key`, each a string in tailcat's text
encoding; `private_key` and `preshared_key` are
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
strings.

## Details

The private key and the pre-shared key are secrets. They are
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
strings, so [`print()`](https://rdrr.io/r/base/print.html),
[`format()`](https://rdrr.io/r/base/format.html), and
[`str()`](https://rdrr.io/r/utils/str.html) of the keys, or of the
elements, show only the public key and `<redacted>`. The elements still
hold the full values
([`as.character()`](https://rdrr.io/r/base/character.html) or
[`unclass()`](https://rdrr.io/r/base/class.html) returns them, and
[`dput()`](https://rdrr.io/r/base/dput.html) shows them), so store them
securely, for example with
[`saveRDS()`](https://rdrr.io/r/base/readRDS.html) to a file only you
can read.

## Examples

``` r
keys = tailcat_keygen()
keys
#> <tailcat_keys>
#>   public_key:    nodekey:6bbcec847f8faecd77121101d2d7599b6230c62dd764f0007a0f32297a5c5c68
#>   private_key:   <redacted>
#>   preshared_key: <redacted>
keys$public_key
#> [1] "nodekey:6bbcec847f8faecd77121101d2d7599b6230c62dd764f0007a0f32297a5c5c68"
```
