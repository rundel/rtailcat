# rtailcat: Peer-to-Peer Network Connections with 'tailcat'

The package statically links the 'tailcat' Go library, which embeds a Go
runtime in the R process. That runtime cannot be unloaded, so the
package never unloads its shared object, and it cannot be used after
`fork()` without `exec()`: every native entry point refuses to run in a
forked child (for example inside
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html)).

## See also

Useful links:

- <https://github.com/tailscale/tailcat>

## Author

**Maintainer**: Colin Rundel <cr173@duke.edu>

Authors:

- Colin Rundel <cr173@duke.edu>

Other contributors:

- Tailscale Inc & contributors (Author and copyright holder of the
  bundled, statically linked 'tailcat' Go library; see inst/COPYRIGHTS)
  \[copyright holder\]
