# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R
# Edit the vignette, not this file

progress_record = function(monitor, datagram) {
  # Stores one report, ignoring datagrams that are not JSON objects naming their job

  event = tryCatch(
    datagram |> rawToChar() |> jsonlite::fromJSON(),
    error = \(e) NULL
  )
  if (is.list(event) && is.character(event$job) && length(event$job) == 1) {
    monitor$events[[length(monitor$events) + 1]] = event
    monitor$last_seen[[event$job]] = Sys.time()
  }
  invisible(monitor)
}

progress_monitor = function(port = 9000L) {
  # Starts collecting progress reports in the background and returns the monitor

  srv = TailcatServer$new()
  lst = srv$listen(port, network = "udp")
  monitor = new.env(parent = emptyenv())
  monitor$server = srv
  monitor$listener = lst
  monitor$events = list()
  monitor$last_seen = list()

  # A failed flow is closed anyway and there is no one to tell, so its error is
  # dropped instead of becoming a warning
  lst$serve(\(conn) {
    conn$read_loop(
      \(datagram) progress_record(monitor, datagram),
      on_error = \(e) NULL
    )
  })
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c(
    "Collecting progress reports on UDP port {port}. Address for the jobs:",
    "{address}"
  ))
  structure(monitor, class = "progress_monitor")
}

progress_data = function(monitor) {
  # Returns the reports as a tibble with one row per report, ordered by job and sequence number

  events = monitor$events
  if (length(events) == 0) {
    return(tibble::tibble(job = character(), seq = integer()))
  }

  # Reports may carry different fields
  cols = events |> lapply(names) |> unlist() |> unique()
  rows = lapply(events, \(e) {
    e[setdiff(cols, names(e))] = NA
    tibble::as_tibble(e[cols])
  })
  out = do.call(rbind, rows)
  out[order(out$job, out$seq), ]
}

progress_stop = function(monitor) {
  # Stops collecting reports, closes the monitor's server, and returns the monitor

  monitor$server$close()
  invisible(monitor)
}

print.progress_monitor = function(x, ...) {
  # Shows how many reports have arrived from how many jobs, and whether more can arrive

  n = length(x$events)
  jobs = length(x$last_seen)
  state = if (x$listener$is_serving) "collecting" else "stopped"
  "<progress monitor> {n} report{?s} from {jobs} job{?s} ({state})" |>
    cli::pluralize() |>
    cat("\n", sep = "")
  invisible(x)
}

progress_reporter = function(address, job, port = 9000L) {
  # Connects a job to a monitor and returns a reporter for progress_report()

  cl = TailcatClient$new(address)
  reporter = new.env(parent = emptyenv())
  reporter$client = cl
  reporter$conn = cl$dial(port, network = "udp", timeout = 60)
  reporter$job = job
  reporter$seq = 0L
  reporter$unsent = 0L
  reporter
}

progress_report = function(.reporter, ...) {
  # Sends one report with the fields in `...` and returns the reporter

  fields = list(...)
  reserved = intersect(names(fields), c("job", "seq"))
  if (length(reserved) > 0) {
    cli::cli_abort("A report cannot have {cli::qty(reserved)}field{?s} named {.field {reserved}}.")
  }
  seq = .reporter$seq + 1L
  .reporter$seq = seq
  payload = c(list(job = .reporter$job, seq = seq), fields) |>
    jsonlite::toJSON(auto_unbox = TRUE, digits = NA) |>
    charToRaw()
  limit = tailcat_udp_max_payload()
  if (length(payload) > limit) {
    cli::cli_warn(c(
      "Report {seq} was not sent.",
      "i" = "It is {length(payload)} bytes; a datagram holds at most {limit}."
    ))
    .reporter$unsent = .reporter$unsent + 1L
    return(invisible(.reporter))
  }

  # Monitoring must never slow down or stop the job, so a failed send is
  # given up after a second and only counted
  tryCatch(
    .reporter$conn$write(payload, timeout = 1),
    error = \(e) {
      .reporter$unsent = .reporter$unsent + 1L
    }
  )
  invisible(.reporter)
}

progress_done = function(reporter) {
  # Disconnects the reporter from the monitor and returns the reporter

  reporter$client$close()
  invisible(reporter)
}

progress_app = function(monitor, x = "iter", y = "loss") {
  # A Shiny app plotting `y` against `x` for each job, with their latest reports

  ui = shiny::fluidPage(
    shiny::titlePanel("Job progress"),
    shiny::plotOutput("plot"),
    shiny::tableOutput("latest")
  )
  server = function(input, output, session) {
    # Polling is enough: the monitor collects reports on its own
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
      graphics::legend(
        "topright",
        legend = jobs,
        col = seq_along(jobs),
        lwd = 2,
        bty = "n"
      )
    })
    output$latest = shiny::renderTable({
      d = data()
      shiny::req(nrow(d) > 0)
      latest = d[!duplicated(d$job, fromLast = TRUE), ]
      seen = do.call(c, monitor$last_seen[latest$job])
      latest$age = difftime(Sys.time(), seen, units = "secs") |>
        as.double() |>
        round() |>
        paste("s")
      latest
    })
  }
  shiny::shinyApp(ui, server)
}
