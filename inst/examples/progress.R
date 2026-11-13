# Generated from vignettes/building-on-rtailcat.qmd by tools/vignette.R; edit the vignette, not this file.

progress_monitor = function(port = 9000L) {
  srv = TailcatServer$new()
  lst = srv$listen(port, network = "udp")
  monitor = new.env(parent = emptyenv())
  monitor$server = srv
  monitor$events = list()
  lst$serve(function(conn) {
    conn$read_loop(function(datagram) progress_record(monitor, datagram), on_error = function(e) NULL)
  })
  address = tailcat_reveal(srv$address)
  cli::cli_inform(c("Collecting progress reports on UDP port {port}. Address for the jobs:", " " = "{address}"))
  structure(monitor, class = "progress_monitor")
}

progress_record = function(monitor, datagram) {
  event = tryCatch(jsonlite::fromJSON(rawToChar(datagram)), error = function(e) NULL)
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
  cols = unique(unlist(lapply(events, names)))
  rows = lapply(events, function(e) {
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
  jobs = unique(vapply(x$events, function(e) e$job, character(1)))
  cat("<progress monitor>", length(x$events), "reports from", length(jobs), "jobs\n")
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
  payload = charToRaw(jsonlite::toJSON(event, auto_unbox = TRUE, digits = NA))
  if (length(payload) > tailcat_udp_max_payload()) {
    cli::cli_warn("Report {reporter$seq} is {length(payload)} bytes, over the {tailcat_udp_max_payload()} bytes a datagram can hold, and was not sent.")
    return(invisible(FALSE))
  }
  sent = tryCatch(
    {
      reporter$conn$write(payload, timeout = 1)
      TRUE
    },
    error = function(e) FALSE
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
    data = shiny::reactivePoll(
      1000, session,
      checkFunc = function() length(monitor$events),
      valueFunc = function() progress_data(monitor)
    )
    output$plot = shiny::renderPlot({
      d = data()
      shiny::req(nrow(d) > 0, x %in% names(d), y %in% names(d))
      jobs = unique(d$job)
      plot(d[[x]], d[[y]], type = "n", xlab = x, ylab = y)
      for (i in seq_along(jobs)) {
        rows = d$job == jobs[i]
        lines(d[[x]][rows], d[[y]][rows], col = i, lwd = 2)
      }
      legend("topright", legend = jobs, col = seq_along(jobs), lwd = 2, bty = "n")
    })
    output$latest = shiny::renderTable({
      d = data()
      shiny::req(nrow(d) > 0)
      latest = d[!duplicated(d$job, fromLast = TRUE), setdiff(names(d), c("sent", "received")), drop = FALSE]
      latest$age = paste(round(as.double(Sys.time() - d$received[!duplicated(d$job, fromLast = TRUE)], units = "secs")), "s")
      latest
    })
  }
  shiny::shinyApp(ui, server)
}
