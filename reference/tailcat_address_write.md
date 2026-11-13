# Pass a tailcat address through a file

`tailcat_address_write()` writes a server's address to a file that only
the current user can read, and `tailcat_address_read()` reads it back,
for scripts and jobs that hand an address over through a shared file
system rather than printing it. The address is a secret: anyone who can
read it can connect to the server.

## Usage

``` r
tailcat_address_write(address, path, overwrite = FALSE)

tailcat_address_read(path)
```

## Arguments

- address:

  A started
  [TailcatServer](https://rundel.github.io/rtailcat/reference/TailcatServer.md),
  or an address as a string or
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md).

- path:

  Path of the address file.

- overwrite:

  `TRUE` to replace an existing file, `FALSE` (the default) to raise an
  error instead.

## Value

`tailcat_address_write()` returns `path`, invisibly.
`tailcat_address_read()` returns the address as a
[tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md),
after checking that it parses as a tailcat address.

## Details

The file holds the address as a single line of text. On Unix-alikes it
is created with mode `0600` (owner read and write), under a restrictive
umask and moved into place, so it is never readable by others, even
briefly; `tailcat_address_read()` warns if the file can be read by other
users. On Windows file modes do not apply, as described in
[`tailcat_keys_save()`](https://rundel.github.io/rtailcat/reference/tailcat_keys_save.md).

## See also

[`tailcat_reveal()`](https://rundel.github.io/rtailcat/reference/tailcat_reveal.md)
to show or pass on an address explicitly.

## Examples

``` r
if (FALSE) { # \dontrun{
srv = TailcatServer$new()
srv$start()
tailcat_address_write(srv, "~/.config/myjob/address")

# In the job:
cli = TailcatClient$new(tailcat_address_read("~/.config/myjob/address"))
} # }
```
