#' Save and load tailcat keys
#'
#' `tailcat_keys_save()` writes keys from [tailcat_keygen()] to a file that only the current user can read, and `tailcat_keys_load()` reads them back. Together they give a server a stable address, or a client a stable public key, across R sessions. `tailcat_keygen(path)` combines the two: it loads the keys from `path` if the file exists and otherwise generates keys and saves them there.
#'
#' The file is JSON with the fields `private_key`, `public_key`, and `preshared_key`, in tailcat's text encoding, so it can be inspected and moved between machines. It holds the secrets in plain text: anyone who can read it can run a server at the same address, or connect as the same client. On Unix-alikes the file is created with mode `0600` (owner read and write) and its folder, if it has to be created, with mode `0700`; the file is written under a restrictive umask and moved into place, so it is never readable by others, even briefly. `tailcat_keys_load()` warns if the file can be read by other users. On Windows file modes do not apply: the file gets the permissions of its folder, so keep it in a folder only you can read, such as one in your user profile.
#'
#' @param keys A `tailcat_keys` object from [tailcat_keygen()].
#' @param path Path of the keys file.
#' @param overwrite `TRUE` to replace an existing file. The default, `FALSE`, raises an error instead, so keys in use are not lost by accident.
#' @return `tailcat_keys_save()` returns `path`, invisibly. `tailcat_keys_load()` returns a `tailcat_keys` object, as [tailcat_keygen()] does.
#' @seealso [tailcat_address_write()] to pass an address through a file.
#' @examples
#' path = tempfile(fileext = ".json")
#' keys = tailcat_keygen(path)
#' identical(tailcat_keys_load(path)$public_key, keys$public_key)
#' @export
tailcat_keys_save = function(keys, path, overwrite = FALSE) {
  if (!inherits(keys, "tailcat_keys")) {
    abort_invalid("{.arg keys} must be a {.cls tailcat_keys} object from {.fn tailcat_keygen}.")
  }
  key = check_key(keys)
  path = check_path(path)
  check_flag(overwrite, "overwrite")
  json = jsonlite::toJSON(
    list(private_key = key$private_key, public_key = enc2utf8(keys$public_key), preshared_key = key$preshared_key),
    auto_unbox = TRUE, pretty = TRUE
  )
  write_private(as.character(json), path, overwrite)
  invisible(path)
}

#' @rdname tailcat_keys_save
#' @export
tailcat_keys_load = function(path) {
  path = check_path(path)
  text = read_private(path, "keys")
  fields = c("private_key", "public_key", "preshared_key")
  keys = tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE), error = function(e) NULL)
  valid = is.list(keys) && all(vapply(fields, function(f) {
    x = keys[[f]]
    is.character(x) && length(x) == 1 && !is.na(x) && nzchar(x)
  }, logical(1)))
  if (!valid) {
    abort_invalid(c(
      "{.path {path}} is not a tailcat keys file.",
      i = "It must be JSON with the string fields {.field private_key}, {.field public_key}, and {.field preshared_key}, as written by {.fn tailcat_keys_save}."
    ))
  }
  new_keys(keys$private_key, keys$public_key, keys$preshared_key)
}

#' Pass a tailcat address through a file
#'
#' `tailcat_address_write()` writes a server's address to a file that only the current user can read, and `tailcat_address_read()` reads it back, for scripts and jobs that hand an address over through a shared file system rather than printing it. The address is a secret: anyone who can read it can connect to the server.
#'
#' The file holds the address as a single line of text. On Unix-alikes it is created with mode `0600` (owner read and write), under a restrictive umask and moved into place, so it is never readable by others, even briefly; `tailcat_address_read()` warns if the file can be read by other users. On Windows file modes do not apply, as described in [tailcat_keys_save()].
#'
#' @param address A started [TailcatServer], or an address as a string or [tailcat_secret].
#' @param path Path of the address file.
#' @param overwrite `TRUE` to replace an existing file, `FALSE` (the default) to raise an error instead.
#' @return `tailcat_address_write()` returns `path`, invisibly. `tailcat_address_read()` returns the address as a [tailcat_secret], after checking that it parses as a tailcat address.
#' @seealso [tailcat_reveal()] to show or pass on an address explicitly.
#' @examples
#' \dontrun{
#' srv = TailcatServer$new()
#' srv$start()
#' tailcat_address_write(srv, "~/.config/myjob/address")
#'
#' # In the job:
#' cli = TailcatClient$new(tailcat_address_read("~/.config/myjob/address"))
#' }
#' @export
tailcat_address_write = function(address, path, overwrite = FALSE) {
  if (is_tailcat_object(address, "TailcatServer")) {
    address = address$address
  }
  address = check_address(address)
  path = check_path(path)
  check_flag(overwrite, "overwrite")
  write_private(address, path, overwrite)
  invisible(path)
}

#' @rdname tailcat_address_write
#' @export
tailcat_address_read = function(path) {
  path = check_path(path)
  lines = trimws(strsplit(read_private(path, "address"), "\n", fixed = TRUE)[[1]])
  lines = lines[nzchar(lines)]
  if (length(lines) != 1) {
    abort_invalid("{.path {path}} must hold exactly one address on one line.")
  }
  result = rtc_address_parse(enc2utf8(lines))
  if (inherits(result, "rtc_error")) {
    abort_invalid("{.path {path}} does not hold a valid tailcat address.")
  }
  new_secret(lines)
}

new_keys = function(private_key, public_key, preshared_key) {
  structure(
    list(
      private_key = new_secret(private_key),
      public_key = public_key,
      preshared_key = new_secret(preshared_key)
    ),
    class = "tailcat_keys"
  )
}

check_path = function(path, call = parent.frame()) {
  if (!is.character(path) || length(path) != 1 || is.na(path) || !nzchar(path)) {
    abort_invalid("{.arg path} must be a single non-empty string.", call = call)
  }
  path.expand(path)
}

check_flag = function(x, arg, call = parent.frame()) {
  if (!isTRUE(x) && !isFALSE(x)) {
    abort_invalid("{.arg {arg}} must be {.code TRUE} or {.code FALSE}.", call = call)
  }
  x
}

# The file is written to a temporary name in the same folder under umask 077
# and renamed into place, so it is never readable by others, not even while
# it is being written, and a failed write leaves any old file intact.
write_private = function(text, path, overwrite, call = parent.frame()) {
  if (file.exists(path) && !overwrite) {
    abort_invalid(c("{.path {path}} already exists.", i = "Use {.code overwrite = TRUE} to replace it."), call = call)
  }
  old = Sys.umask("077")
  on.exit(Sys.umask(old), add = TRUE)
  dir = dirname(path)
  if (!dir.exists(dir) && !dir.create(dir, recursive = TRUE, mode = "0700")) {
    tailcat_abort(5L, headline = cli::format_inline("Could not create the folder {.path {dir}}."), call = call)
  }
  tmp = tempfile(".tailcat-", tmpdir = dir)
  on.exit(unlink(tmp), add = TRUE)
  ok = tryCatch({
    con = file(tmp, open = "wb")
    tryCatch(writeLines(text, con, useBytes = TRUE), finally = close(con))
    TRUE
  }, error = function(e) FALSE)
  if (!ok || !file.rename(tmp, path)) {
    tailcat_abort(5L, headline = cli::format_inline("Could not write {.path {path}}."), call = call)
  }
  invisible(path)
}

read_private = function(path, what, call = parent.frame()) {
  if (!file.exists(path) || dir.exists(path)) {
    abort_invalid("The {what} file {.path {path}} does not exist.", call = call)
  }
  if (.Platform$OS.type != "windows") {
    mode = file.mode(path)
    if (!is.na(mode) && bitwAnd(as.integer(mode), strtoi("077", 8L)) != 0) {
      cli::cli_warn(c(
        "The {what} file {.path {path}} can be read by other users.",
        i = "Restrict it with {.code Sys.chmod({deparse(path)}, \"600\")}."
      ), class = "tailcat_warning", call = call)
    }
  }
  text = readChar(path, file.size(path), useBytes = TRUE)
  Encoding(text) = "UTF-8"
  text
}
