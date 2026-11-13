# Secret strings

Tailcat addresses, private keys, and pre-shared keys are returned as
character vectors with class `tailcat_secret`, so that printing them by
accident does not reveal them. `TailcatServer$address`, the `address`
element of `TailcatServer$info()`, the result of
[`tailcat_address_resolve()`](https://rundel.github.io/rtailcat/reference/tailcat_address_resolve.md),
and the `private_key` and `preshared_key` elements of
[`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
are secrets.

[`print()`](https://rdrr.io/r/base/print.html),
[`format()`](https://rdrr.io/r/base/format.html),
[`str()`](https://rdrr.io/r/utils/str.html), and
[`toString()`](https://rdrr.io/r/base/toString.html) show `<redacted>`
instead of the value, and so do printing and
[`str()`](https://rdrr.io/r/utils/str.html) of a list that contains a
secret. [`format()`](https://rdrr.io/r/base/format.html) of a plain list
that contains a secret redacts it in R 4.6.0 and later; earlier versions
of R format list elements without consulting their class, so there it
shows the value. The list returned by `TailcatServer$info()` has class
`tailcat_info` and the list returned by
[`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
has class `tailcat_keys`, and both redact under
[`format()`](https://rdrr.io/r/base/format.html) in every version of R.

Everything else sees the plain string:
[`as.character()`](https://rdrr.io/r/base/character.html),
[`unclass()`](https://rdrr.io/r/base/class.html),
[`paste()`](https://rdrr.io/r/base/paste.html),
[`paste0()`](https://rdrr.io/r/base/paste.html),
[`cat()`](https://rdrr.io/r/base/cat.html),
[`writeLines()`](https://rdrr.io/r/base/writeLines.html),
[`nchar()`](https://rdrr.io/r/base/nchar.html), and
[`identical()`](https://rdrr.io/r/base/identical.html) on the unclassed
value. A secret can be passed directly wherever this package expects an
address or key, such as `TailcatClient$new()` and `TailcatServer$new()`.
Functions that drop attributes, such as
[`c()`](https://rdrr.io/r/base/c.html),
[`unlist()`](https://rdrr.io/r/base/unlist.html), and subsetting with
`[`, return the plain string too.

Redaction only protects against accidental display.
[`dput()`](https://rdrr.io/r/base/dput.html),
[`deparse()`](https://rdrr.io/r/base/deparse.html),
[`saveRDS()`](https://rdrr.io/r/base/readRDS.html), and
[`save()`](https://rdrr.io/r/base/save.html) necessarily include the
value, as does any explicit conversion with
[`as.character()`](https://rdrr.io/r/base/character.html) or
[`unclass()`](https://rdrr.io/r/base/class.html), so store and share
secrets deliberately.

## Usage

``` r
# S3 method for class 'tailcat_secret'
format(x, ...)

# S3 method for class 'tailcat_secret'
print(x, ...)

# S3 method for class 'tailcat_secret'
str(object, ...)

# S3 method for class 'tailcat_secret'
toString(x, ...)

# S3 method for class 'tailcat_info'
format(x, ...)

# S3 method for class 'tailcat_info'
print(x, ...)

# S3 method for class 'tailcat_info'
str(object, ...)
```

## Arguments

- x, object:

  A `tailcat_secret`, or the `tailcat_info` list returned by
  `TailcatServer$info()`.

- ...:

  Ignored.

## Value

[`format()`](https://rdrr.io/r/base/format.html) and
[`toString()`](https://rdrr.io/r/base/toString.html) return
`"<redacted>"` for each element of a secret;
[`format()`](https://rdrr.io/r/base/format.html) of a `tailcat_info`
list returns a named character vector with its secrets redacted;
[`print()`](https://rdrr.io/r/base/print.html) and
[`str()`](https://rdrr.io/r/utils/str.html) return their input
invisibly.

## Examples

``` r
keys = tailcat_keygen()
keys$private_key
#> <tailcat_secret> <redacted> 
str(keys)
#> List of 3 (class tailcat_keys)
#>  $ private_key  : <tailcat_secret> <redacted> 
#>  $ public_key   : chr "nodekey:a61d0b88482ddc79660036e36d6f87e764d94876e0ca6e802d43be4388de487a" 
#>  $ preshared_key: <tailcat_secret> <redacted> 
nchar(keys$private_key) > 0
#> [1] TRUE
```
