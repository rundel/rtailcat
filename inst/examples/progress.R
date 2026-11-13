# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R; edit the vignette, not this file.

progress_monitor = function(port = 9000L) {
  srv = TailcatServer$new()
  lst = srv$listen(port, network = "udp")
  monitor = new.env(parent = emptyenv())
  monitor$server = srv
  monitor$events = list()
  # One flow per job. A flow that fails is closed; there is nothing to report.
  lst$serve(\(conn) {
    conn$read_loop(\(datagram) progress_record(monitor, datagram), on_error = \(e) NULL)
  })
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c(
    "Collecting progress reports on UDP port {port}. Address for the jobs:",
    "{address}"
  ))
  structure(monitor, class = "progress_monitor")
}

progress_record = function(monitor, datagram) {
  event = tryCatch(
    datagram |> rawToChar() |> jsonlite::fromJSON(),
    error = \(e) NULL
  )
  if (is.list(event)) {
    event$received = Sys.time()
    monitor$events[[length(monitor$events) + 1]] = event
  }
  invisible()
}

progress_data = function(monitor) {
  events = monitor$events
  if (length(events) == 0) {
    return(data.frame())
  }
  # Reports may carry different fields, so fill the missing ones with NA.
  cols = events |> lapply(names) |> unlist() |> unique()
  rows = lapply(events, \(e) {
    e[setdiff(cols, names(e))] = NA
    as.data.frame(e[cols])
  })
  out = do.call(rbind, rows)
  out = out[order(out$job, out$seq), , drop = FALSE]
  rownames(out) = NULL
  out
}

progress_stop = function(monitor) {
  monitor$server$close()
  invisible()
}

print.progress_monitor = function(x, ...) {
  n = length(x$events)
  jobs = vapply(x$events, \(e) e$job, character(1)) |> unique() |> length()
  cat(cli::pluralize("<progress monitor> {n} report{?s} from {jobs} job{?s}"), "\n", sep = "")
  invisible(x)
}

progress_reporter = function(address, job, port = 9000L) {
  cl = TailcatClient$new(address)
  reporter = new.env(parent = emptyenv())
  reporter$client = cl
  reporter$conn = cl$dial(port, network = "udp", timeout = 60)
  reporter$job = job
  reporter$seq = 0L
  reporter
}

progress_report = function(reporter, ...) {
  reporter$seq = reporter$seq + 1L
  event = list(job = reporter$job, seq = reporter$seq, sent = as.numeric(Sys.time()), ...)
  payload = event |>
    jsonlite::toJSON(auto_unbox = TRUE, digits = NA) |>
    charToRaw()
  limit = tailcat_udp_max_payload()
  if (length(payload) > limit) {
    cli::cli_warn(
      "Report {reporter$seq} is {length(payload)} bytes, over the {limit} bytes a datagram can hold, and was not sent."
    )
    return(invisible(FALSE))
  }
  # Monitoring must never slow down or stop the job, so a failed send is
  # given up after a second and otherwise ignored.
  sent = tryCatch(
    {
      reporter$conn$write(payload, timeout = 1)
      TRUE
    },
    error = \(e) FALSE
  )
  invisible(sent)
}

progress_done = function(reporter) {
  reporter$client$close()
  invisible()
}

progress_app = function(monitor, x = "iter", y = "loss") {
  ui = shiny::fluidPage(
    shiny::titlePanel("Job progress"),
    shiny::plotOutput("plot"),
    shiny::tableOutput("latest")
  )
  server = function(input, output, session) {
    # Polling is enough: the monitor collects reports on its own.
    data = shiny::reactivePoll(
      1000,
      session,
      checkFunc = \() length(monitor$events),
      valueFunc = \() progress_data(monitor)
    )
    output$plot = shiny::renderPlot({
      d = data()
      shiny::req(nrow(d) > 0, x %in% names(d), y %in% names(d))
      jobs = unique(d$job)
      graphics::plot(d[[x]], d[[y]], type = "n", xlab = x, ylab = y)
      for (i in seq_along(jobs)) {
        rows = d$job == jobs[i]
        graphics::lines(d[[x]][rows], d[[y]][rows], col = i, lwd = 2)
      }
      graphics::legend("topright", legend = jobs, col = seq_along(jobs), lwd = 2, bty = "n")
    })
    output$latest = shiny::renderTable({
      d = data()
      shiny::req(nrow(d) > 0)
      last = !duplicated(d$job, fromLast = TRUE)
      latest = d[last, setdiff(names(d), c("sent", "received")), drop = FALSE]
      latest$age = difftime(Sys.time(), d$received[last], units = "secs") |>
        as.double() |>
        round() |>
        paste("s")
      latest
    })
  }
  shiny::shinyApp(ui, server)
}
