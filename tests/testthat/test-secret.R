# toString() of a list is paste(), which shows values like as.character().
# Before R 4.6.0 format() of a plain list ignores the class of its elements, so it cannot redact.
every_display = function(x) {
  plain_list = is.list(x) && !is.object(x)
  c(
    utils::capture.output(print(x)),
    utils::capture.output(utils::str(x)),
    if (!is.environment(x) && (!plain_list || getRversion() >= "4.6.0")) format(x),
    if (is.character(x)) toString(x)
  )
}

expect_hidden = function(outputs, secrets) {
  for (secret in secrets) {
    expect_false(any(grepl(secret, outputs, fixed = TRUE)))
  }
}

bare = function(secrets) {
  c(secrets, sub("^[a-z]+:", "", secrets))
}

test_that("a tailcat_secret redacts every display but keeps its value for use", {
  value = "tcSECRETvalue0123456789"
  secret = rtailcat:::new_secret(value)
  expect_s3_class(secret, "tailcat_secret")
  expect_hidden(every_display(secret), value)
  expect_hidden(every_display(list(address = secret, other = 1)), value)
  expect_identical(format(secret), "<redacted>")
  expect_identical(toString(secret), "<redacted>")
  expect_match(utils::capture.output(print(secret)), "<redacted>", fixed = TRUE)

  expect_identical(as.character(secret), value)
  expect_identical(unclass(secret), value)
  expect_identical(paste0(secret), value)
  expect_identical(paste("x", secret), paste("x", value))
  expect_identical(nchar(secret), nchar(value))
  path = withr::local_tempfile()
  writeLines(secret, path)
  expect_identical(readLines(path), value)
  expect_match(paste(deparse(secret), collapse = ""), value, fixed = TRUE)
})

test_that("tailcat_keys hide their secrets from print, format, str, and list walking", {
  keys = tailcat_keygen()
  secrets = bare(c(keys$private_key, keys$preshared_key))
  expect_s3_class(keys$private_key, "tailcat_secret")
  expect_s3_class(keys$preshared_key, "tailcat_secret")
  expect_type(keys$public_key, "character")
  expect_false(inherits(keys$public_key, "tailcat_secret"))

  outputs = c(every_display(keys), every_display(unclass(keys)))
  for (element in as.list(keys)) {
    outputs = c(outputs, every_display(element))
  }
  expect_hidden(outputs, secrets)
  expect_match(paste(utils::capture.output(utils::str(keys)), collapse = "\n"), keys$public_key, fixed = TRUE)
  expect_match(paste(utils::capture.output(utils::str(keys)), collapse = "\n"), "<redacted>", fixed = TRUE)

  # dput() necessarily shows the values; it is the documented way to see them.
  expect_match(paste(utils::capture.output(dput(keys)), collapse = ""), unclass(keys$private_key), fixed = TRUE)
  expect_match(as.character(keys$private_key), "^privkey:")
})

test_that("secret keys can be passed wherever a key is expected", {
  keys = tailcat_keygen()
  srv = TailcatServer$new(key = keys$private_key, preshared_key = keys$preshared_key)
  on.exit(srv$close())
  expect_identical(srv$public_key, NA_character_)
  cl = TailcatClient$new(tc_address(list(p = as.raw(1:32), k = as.raw(33:64), i = 10)), key = keys$private_key)
  on.exit(cl$close(), add = TRUE)
  expect_identical(cl$public_key, keys$public_key)
})

test_that("a saved and reloaded server holds no address and is closed", {
  skip_relay()
  srv = relay_server()
  srv$start()
  address = unclass(srv$address)
  expect_s3_class(srv$address, "tailcat_secret")
  expect_s3_class(srv$info()$address, "tailcat_secret")
  expect_hidden(c(every_display(srv$info()), every_display(srv$address), printed(srv)), address)

  for (field in as.list(srv)) {
    if (!is.function(field)) {
      expect_hidden(every_display(field), address)
    }
  }
  for (field in as.list(srv$.__enclos_env__$private)) {
    if (!is.function(field)) {
      expect_hidden(utils::capture.output(dput(field)), address)
    }
  }

  path = withr::local_tempfile(fileext = ".rds")
  saveRDS(srv, path, compress = FALSE)
  bytes = readBin(path, "raw", file.size(path))
  expect_length(grepRaw(address, bytes, fixed = TRUE), 0)

  copy = readRDS(path)
  expect_true(copy$is_closed)
  expect_error(copy$address, class = "tailcat_closed")
  expect_error(copy$listen(0), class = "tailcat_closed")
  expect_match(printed(copy), "closed", fixed = TRUE)
  expect_false(srv$is_closed)
  expect_identical(unclass(srv$address), address)
})

test_that("the resolved address is a secret that still works for connecting", {
  skip_relay()
  srv = relay_server()
  srv$start()
  resolved = tailcat_address_resolve(srv$address, derp_map_url = relay_derp_map_url(), timeout = 30)
  expect_s3_class(resolved, "tailcat_secret")
  expect_hidden(every_display(resolved), unclass(resolved))
  resolved_async = wait_for(tailcat_address_resolve_async(srv$address, derp_map_url = relay_derp_map_url(), timeout = 30), 40)
  expect_s3_class(resolved_async, "tailcat_secret")
})
