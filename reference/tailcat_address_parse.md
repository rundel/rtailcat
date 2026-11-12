# Inspect a tailcat address

Parses a tailcat address locally, without network access, and returns
its public metadata. The pre-shared key embedded in the address is
deliberately not returned.

## Usage

``` r
tailcat_address_parse(address)
```

## Arguments

- address:

  A tailcat address, as a string or the
  [tailcat_secret](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  returned by `TailcatServer$address`. Surrounding whitespace is
  ignored. Addresses are secrets.

## Value

A list with elements

- `public_key`, the server's public key;

- `disco_public_key`, the server's discovery key;

- `has_preshared_key`, `TRUE` if the address carries a pre-shared key;

- `region_id`, the number of the relay region the server registered in.
  `0` means the address names no region number: its relay details are
  embedded in `regions` instead, or (for an address that has neither)
  are missing, and a client cannot use it;

- `regions`, the relay regions embedded in the address, or `NULL`. Each
  is a list with `region_id`, `region_code`, `region_name`, and `nodes`;
  each node is a list with fields such as `name`, `region_id`,
  `host_name`, `cert_name`, `ipv4`, `ipv6`, `stun_port`, `relay_port`,
  and `insecure_for_tests` (fields tailcat omits are absent).

Field names are snake_case versions of tailcat's (which follow
Tailscale's `DERPRegion` and `DERPNode` types), with the relay (DERP)
port as `relay_port`.

## Examples

``` r
try(tailcat_address_parse("not an address"))
#> Error in tailcat_address_parse("not an address") : `address` is invalid.
#> ℹ tailcat: invalid tailcat address
```
