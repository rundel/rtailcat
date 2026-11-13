# Reads that take several steps ($read_all(), $read_exact(), $read_message(),
# and the read loop) share one driver for sync and async calls. A reader is a
# list of functions:
#
# - start(): NULL to start reading, or a result when nothing needs to be read.
# - want(): the number of bytes to ask for in the next read.
# - feed(chunk): takes a chunk, or NULL at end of stream, and returns NULL to
#   keep reading or a result.
# - total(): the bytes consumed so far, for the condition's `bytes` field.
#
# A result is list(value = ) when the reader is done, or list(error = ) with
# tailcat_condition() arguments when the data is unacceptable.

reader_done = function(value) {
  list(value = value)
}

reader_failed = function(headline, bytes, bullets = NULL) {
  list(error = list(status = 5L, headline = headline, bullets = bullets, bytes = byte_total(bytes)))
}

join_chunks = function(chunks) {
  do.call(c, c(list(raw(0)), chunks))
}

max_read_size = 65536

# One read: a chunk (TCP) or a datagram (UDP), or NULL at end of stream.
single_reader = function(n = max_read_size) {
  got = 0
  list(
    start = function() NULL,
    want = function() n,
    total = function() got,
    feed = function(chunk) {
      got <<- length(chunk)
      reader_done(chunk)
    }
  )
}

all_reader = function(max_bytes) {
  chunks = list()
  got = 0
  list(
    start = function() NULL,
    want = function() read_all_chunk(max_bytes, got),
    total = function() got,
    feed = function(chunk) {
      if (is.null(chunk)) {
        return(reader_done(join_chunks(chunks)))
      }
      chunks[[length(chunks) + 1L]] <<- chunk
      got <<- got + length(chunk)
      if (got > max_bytes) {
        return(reader_failed(too_long_headline(max_bytes), got, too_long_bullets))
      }
      NULL
    }
  )
}

# Exactly n bytes, or NULL if the stream ends before the first one.
exact_reader = function(n) {
  chunks = list()
  got = 0
  list(
    start = function() if (n == 0) reader_done(raw(0)) else NULL,
    want = function() min(max_read_size, n - got),
    total = function() got,
    feed = function(chunk) {
      if (is.null(chunk)) {
        if (got == 0) {
          return(reader_done(NULL))
        }
        return(reader_failed(paste0("The stream ended after ", format_count(got), " of ", format_count(n), " bytes."), got, ended_bullets))
      }
      chunks[[length(chunks) + 1L]] <<- chunk
      got <<- got + length(chunk)
      if (got >= n) reader_done(join_chunks(chunks)) else NULL
    }
  )
}

# A message: a 4-byte unsigned big-endian length, then that many bytes.
message_reader = function(max_bytes) {
  header = raw(0)
  body = NULL
  size = NA_real_
  list(
    start = function() NULL,
    want = function() {
      if (is.null(body)) 4 - length(header) else body$want()
    },
    total = function() length(header) + if (is.null(body)) 0 else body$total(),
    feed = function(chunk) {
      if (!is.null(body)) {
        if (is.null(chunk)) {
          got = body$total()
          return(reader_failed(paste0("The stream ended after ", format_count(got), " of the message's ", format_count(size), " bytes."), 4 + got, ended_bullets))
        }
        return(body$feed(chunk))
      }
      if (is.null(chunk)) {
        if (length(header) == 0) {
          return(reader_done(NULL))
        }
        return(reader_failed("The stream ended in the middle of a message header.", length(header), ended_bullets))
      }
      header <<- c(header, chunk)
      if (length(header) < 4) {
        return(NULL)
      }
      size <<- decode_length(header)
      if (size > max_bytes || size > .Machine$integer.max) {
        limit = min(max_bytes, .Machine$integer.max)
        return(reader_failed(
          paste0("The message is ", format_count(size), " bytes, more than `max_bytes` (", format_count(limit), ")."),
          4, message_skipped_bullets
        ))
      }
      if (size == 0) {
        return(reader_done(raw(0)))
      }
      body <<- exact_reader(size)
      NULL
    }
  )
}

ended_bullets = c(i = "The bytes read were discarded.")

message_skipped_bullets = c(i = "Only the message's length was read; the rest of the stream is the unread message, so close the connection.")

decode_length = function(header) {
  sum(as.double(as.integer(header)) * 256^(3:0))
}

encode_length = function(n) {
  as.raw(c(n %/% 2^24, (n %/% 2^16) %% 256, (n %/% 2^8) %% 256, n %% 256))
}

format_count = function(n) {
  format(n, scientific = FALSE, big.mark = ",")
}

# Runs a reader with blocking reads. `context` holds the tailcat_condition()
# arguments that describe the operation.
run_reader = function(handle, reader, timeout, context, call) {
  deadline = deadline_from(timeout)
  out = reader$start()
  while (is.null(out)) {
    result = rtc_conn_read(handle, reader$want(), remaining_until(deadline), NULL)
    if (inherits(result, "rtc_error")) {
      rlang::exec(rtc_abort, result, !!!context, bytes = byte_total(reader$total()), call = call)
    }
    out = reader$feed(result)
  }
  if (!is.null(out$error)) {
    rlang::exec(tailcat_abort, !!!out$error, call = call)
  }
  out$value
}

# Runs a reader with asynchronous reads, calling exactly one of done(value),
# fail(cond), each from the later event loop (or at once, when start() needs no
# read). Returns a function that cancels the read in flight and starts no more.
start_reader = function(handle, reader, timeout, context, call, done, fail) {
  deadline = deadline_from(timeout)
  state = new.env(parent = emptyenv())
  state$canceled = FALSE
  state$cancel = NULL
  failed = function(result) {
    fail(rlang::exec(rtc_condition, result, !!!context, bytes = byte_total(reader$total()), call = call))
  }
  finish = function(out) {
    if (!is.null(out$error)) {
      fail(rlang::exec(tailcat_condition, !!!out$error, call = call))
    } else {
      done(out$value)
    }
  }
  step = function() {
    if (state$canceled) {
      failed(canceled_error())
      return(invisible())
    }
    state$cancel = rtc_conn_read(handle, reader$want(), remaining_until(deadline), rtc_callback(
      function(result) {
        if (inherits(result, "rtc_error")) {
          failed(result)
          return(invisible())
        }
        out = reader$feed(result)
        if (is.null(out)) step() else finish(out)
      },
      on_error = fail
    ))
    invisible()
  }
  out = reader$start()
  if (is.null(out)) step() else finish(out)
  function() {
    state$canceled = TRUE
    if (!is.null(state$cancel)) {
      rtc_cancel(state$cancel)
    }
    invisible()
  }
}

reader_promise = function(handle, reader, timeout, context, call, transform = identity) {
  canceler = NULL
  p = promises::promise(function(resolve, reject) {
    canceler <<- start_reader(handle, reader, timeout, context, call,
      done = function(value) resolve(transform(value)),
      fail = reject
    )
  })
  with_canceler(p, function() if (!is.null(canceler)) canceler())
}
