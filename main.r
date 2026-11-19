# Based on https://github.com/petegordon/RCloudRun
library(plumber)

r <- plumb("rest_controller.r")

# Report the installed EJAM package version in the Swagger/OpenAPI metadata,
# and preserve the build-time git ref separately as provenance.
r <- plumber::pr_set_api_spec(r, function(spec) {
  spec$info$version <- as.character(utils::packageVersion("EJAM"))

  ejam_ref <- Sys.getenv("EJAM_VERSION")
  if (nzchar(ejam_ref)) {
    description <- spec$info$description
    if (is.null(description) || length(description) != 1L || is.na(description)) {
      description <- ""
    }
    separator <- if (nzchar(description)) "\n\n" else ""
    spec$info$description <- paste0(
      description,
      separator,
      "Built from EJAM ref: ",
      ejam_ref
    )
  }

  spec
})

# Build two throwaway reports before accepting requests, so the first real
# report is as fast as later ones (EJAM#771). Never stops the API from starting.
tryCatch({
  source("warmup.R")
  warmup_reports()
}, error = function(e) message("EJAM warm-up: skipped after error: ", conditionMessage(e)))

r$run(port=8080, host="0.0.0.0")
