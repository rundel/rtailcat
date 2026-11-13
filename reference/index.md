# Package index

## Servers and listeners

Publish a secret address and accept TCP connections or UDP flows.

- [`TailcatServer`](https://rundel.github.io/rtailcat/reference/TailcatServer.md)
  : Tailcat server
- [`TailcatListener`](https://rundel.github.io/rtailcat/reference/TailcatListener.md)
  : Tailcat listener

## Clients

Dial a server by its address.

- [`TailcatClient`](https://rundel.github.io/rtailcat/reference/TailcatClient.md)
  : Tailcat client

## Connections

Read from and write to a TCP stream or UDP flow.

- [`TailcatConnection`](https://rundel.github.io/rtailcat/reference/TailcatConnection.md)
  : Tailcat connection

## Asynchronous operations

Cancel a pending operation, or run the event loop from a script.

- [`tailcat_cancel()`](https://rundel.github.io/rtailcat/reference/tailcat_cancel.md)
  : Cancel a pending asynchronous operation
- [`tailcat_wait()`](https://rundel.github.io/rtailcat/reference/tailcat_wait.md)
  [`tailcat_run()`](https://rundel.github.io/rtailcat/reference/tailcat_wait.md)
  : Run the event loop from a script

## Keys and addresses

Create keys and inspect or resolve addresses locally.

- [`tailcat_keygen()`](https://rundel.github.io/rtailcat/reference/tailcat_keygen.md)
  : Generate tailcat keys
- [`tailcat_keys_save()`](https://rundel.github.io/rtailcat/reference/tailcat_keys_save.md)
  [`tailcat_keys_load()`](https://rundel.github.io/rtailcat/reference/tailcat_keys_save.md)
  : Save and load tailcat keys
- [`tailcat_address_parse()`](https://rundel.github.io/rtailcat/reference/tailcat_address_parse.md)
  : Inspect a tailcat address
- [`tailcat_address_resolve()`](https://rundel.github.io/rtailcat/reference/tailcat_address_resolve.md)
  [`tailcat_address_resolve_async()`](https://rundel.github.io/rtailcat/reference/tailcat_address_resolve.md)
  : Embed relay details in a tailcat address
- [`tailcat_address_write()`](https://rundel.github.io/rtailcat/reference/tailcat_address_write.md)
  [`tailcat_address_read()`](https://rundel.github.io/rtailcat/reference/tailcat_address_write.md)
  : Pass a tailcat address through a file

## Secrets

Redacted strings for addresses and keys.

- [`format(`*`<tailcat_secret>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`print(`*`<tailcat_secret>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`str(`*`<tailcat_secret>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`toString(`*`<tailcat_secret>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`format(`*`<tailcat_info>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`print(`*`<tailcat_info>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  [`str(`*`<tailcat_info>`*`)`](https://rundel.github.io/rtailcat/reference/tailcat_secret.md)
  : Secret strings
- [`tailcat_reveal()`](https://rundel.github.io/rtailcat/reference/tailcat_reveal.md)
  : Reveal a secret

## Limits and build information

- [`tailcat_udp_max_payload()`](https://rundel.github.io/rtailcat/reference/tailcat_udp_max_payload.md)
  : Largest UDP datagram
- [`tailcat_build_info()`](https://rundel.github.io/rtailcat/reference/tailcat_build_info.md)
  : Build information for the embedded tailcat library
