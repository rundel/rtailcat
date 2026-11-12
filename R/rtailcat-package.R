#' rtailcat: Peer-to-Peer Network Connections with 'tailcat'
#'
#' The package statically links the 'tailcat' Go library, which embeds a Go runtime in the R process. That runtime cannot be unloaded, so the package never unloads its shared object, and it cannot be used after `fork()` without `exec()`: every native entry point refuses to run in a forked child (for example inside `parallel::mclapply()`).
#'
#' @keywords internal
#' @importFrom later later
#' @useDynLib rtailcat, .registration = TRUE
"_PACKAGE"
