# Reveal a secret

Returns the plain string held by a
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md),
for the places where an application means to show or pass on an address
or key, such as printing a server's address once for the user to copy,
or putting it into a message. It is the explicit form of
[`as.character()`](https://rdrr.io/r/base/character.html), so the intent
is visible in the code. To pass an address through a file, use
[`tailcat_address_write()`](https://rundel.github.io/rtailcat/reference/tailcat_address_write.md).

## Usage

``` r
tailcat_reveal(x)
```

## Arguments

- x:

  A
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md),
  or a plain character vector, which is returned unchanged.

## Value

A character vector without the `tailcat_secret` class.

## Examples

``` r
keys = tailcat_keygen()
keys$private_key
#> <tailcat_secret> <redacted> 
nchar(tailcat_reveal(keys$private_key)) > 0
#> [1] TRUE
```
