#' Largest UDP datagram
#'
#' The largest payload, in bytes, that one UDP datagram can carry over tailcat. `TailcatConnection$write()` on a UDP connection raises a `tailcat_invalid_argument` error for larger data, so check the size first when the data varies.
#'
#' @return `1232L`.
#' @examples
#' payload = charToRaw("progress: 50%")
#' length(payload) <= tailcat_udp_max_payload()
#' @export
tailcat_udp_max_payload = function() {
  udp_max_payload
}

#' Build information for the embedded tailcat library
#'
#' @return A list of class `tailcat_build_info` with elements `abi_version` (the C ABI version, an integer), `go_version`, `tailcat_version`, and `raw`, the full Go build metadata exactly as Go reports it (with Go's own field names, such as `GoVersion`, `Main`, `Deps`, and `Settings`). Printing it shows the three versions and only summarizes `raw`.
#' @examples
#' tailcat_build_info()
#' @export
tailcat_build_info = function() {
  info = from_json(rtc_value(rtc_build_info(), op = "get build information"))
  go = info$go %||% list()
  structure(
    list(
      abi_version = rtc_abi_version(),
      go_version = go$GoVersion %||% NA_character_,
      tailcat_version = go$Main$Version %||% NA_character_,
      raw = go
    ),
    class = "tailcat_build_info"
  )
}

#' @export
format.tailcat_build_info = function(x, ...) {
  modules = length(x$raw$Deps)
  c(
    "<tailcat_build_info>",
    paste0("  tailcat_version: ", x$tailcat_version),
    paste0("  go_version:      ", x$go_version),
    paste0("  abi_version:     ", x$abi_version),
    paste0("  raw:             Go's build metadata, with ", modules, " bundled modules")
  )
}

#' @export
print.tailcat_build_info = function(x, ...) {
  cat(format(x, ...), sep = "\n")
  invisible(x)
}
