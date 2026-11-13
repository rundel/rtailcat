# Save and load tailcat keys

`tailcat_keys_save()` writes keys from
[`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
to a file that only the current user can read, and `tailcat_keys_load()`
reads them back. Together they give a server a stable address, or a
client a stable public key, across R sessions. `tailcat_keygen(path)`
combines the two: it loads the keys from `path` if the file exists and
otherwise generates keys and saves them there.

## Usage

``` r
tailcat_keys_save(keys, path, overwrite = FALSE)

tailcat_keys_load(path)
```

## Arguments

- keys:

  A `tailcat_keys` object from
  [`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md).

- path:

  Path of the keys file.

- overwrite:

  `TRUE` to replace an existing file. The default, `FALSE`, raises an
  error instead, so keys in use are not lost by accident.

## Value

`tailcat_keys_save()` returns `path`, invisibly. `tailcat_keys_load()`
returns a `tailcat_keys` object, as
[`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
does.

## Details

The file is JSON with the fields `private_key`, `public_key`, and
`preshared_key`, in tailcat's text encoding, so it can be inspected and
moved between machines. It holds the secrets in plain text: anyone who
can read it can run a server at the same address, or connect as the same
client. On Unix-alikes the file is created with mode `0600` (owner read
and write) and its folder, if it has to be created, with mode `0700`;
the file is written under a restrictive umask and moved into place, so
it is never readable by others, even briefly. `tailcat_keys_load()`
warns if the file can be read by other users. On Windows file modes do
not apply: the file gets the permissions of its folder, so keep it in a
folder only you can read, such as one in your user profile.

## See also

[`tailcat_address_write()`](https://rundel.github.io/rtailcat/reference/tailcat_address_write.md)
to pass an address through a file.

## Examples

``` r
path = tempfile(fileext = ".json")
keys = tailcat_keygen(path)
identical(tailcat_keys_load(path)$public_key, keys$public_key)
#> [1] TRUE
```
