# Warm-up at start-up (Public-Environmental-Data-Partners/EJAM#771, part of EJAM#720).
#
# On a new container, the first report used to take 20-35 s longer than later ones:
# it loaded about 29 more R packages, two more data files, pandoc, and (for PDF)
# headless Chrome. warmup_reports() builds two small throwaway reports before the
# API starts accepting requests, so the first real report is as fast as later ones:
#   - one point (3 mi) as PDF, the default for one-site report links
#   - one county as HTML, which also loads the FIPS lookup data
#
# Cloud Run sends requests only once the port is open, so a request that woke the
# container waits for the warm-up too; that one request is not faster. The gain is
# for requests after it, and for containers woken early by /warmup (EJAM#772, #773).
#
# A failure here never stops the API: it is logged, and the API starts anyway.
# Set EJAM_WARMUP=false to skip the warm-up.

warmup_reports <- function() {
  if (tolower(Sys.getenv("EJAM_WARMUP", "true")) %in% c("false", "0", "no")) {
    message("EJAM warm-up: skipped (EJAM_WARMUP=", Sys.getenv("EJAM_WARMUP"), ")")
    return(invisible(NULL))
  }
  step <- function(label, expr) {
    t0 <- Sys.time()
    ok <- tryCatch({
      suppressWarnings(suppressMessages(force(expr)))
      TRUE
    }, error = function(e) {
      message("EJAM warm-up: ", label, " FAILED (API starts anyway): ", conditionMessage(e))
      FALSE
    })
    if (ok) {
      message(sprintf("EJAM warm-up: %s done in %.1f s", label,
                      as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    }
    invisible(ok)
  }

  step("point report, PDF", {
    out <- EJAM::ejam2report(
      EJAM::ejamit(sitepoints = data.frame(lat = 38.9, lon = -77.03), radius = 3),
      sitenumber = 1, return_html = FALSE, launch_browser = FALSE,
      site_method = "latlon", shp = NULL, fileextension = "pdf"
    )
    if (is.character(out) && length(out) == 1 && file.exists(out)) unlink(out)
  })

  step("county report, HTML", {
    # Kent County, Delaware: small and quick. shp = NULL, as GET /report passes for FIPS.
    EJAM::ejam2report(
      EJAM::ejamit(fips = "10001", radius = 0),
      sitenumber = 1, return_html = TRUE, launch_browser = FALSE,
      site_method = "FIPS", shp = NULL, fileextension = "html"
    )
  })

  invisible(gc())
}
