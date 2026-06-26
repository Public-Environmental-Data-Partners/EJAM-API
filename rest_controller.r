# Load necessary libraries
library(rlang)
library(plumber)
library(EJAM)
library(geojsonsf)
library(jsonlite)
library(sf)

# Centralized error handling function
handle_error <- function(message, type = "json") {
  if (type == "html") {
    return(paste0("<html><body><h3>Error</h3><p>", message, "</p></body></html>"))
  }
  return(list(error = message))
}

# The fipper function processes FIPS inputs, converting area names (e.g., states)
# to the appropriate FIPS codes for the specified scale (e.g., counties).
fipper <- function(area, scale = "blockgroup") {
  fips_area <- tryCatch(
    name2fips(area),
    warning = function(w) {
      # If a warning occurs, it's likely the input is already a FIPS code.
      return(area)
    }
  )
  
  # Determine the type of the provided FIPS code.
  fips_type <- fipstype(fips_area)[1]
  
  if (fips_type == scale) {
    return(fips_area)
  }
  
  # Convert the FIPS code to the desired scale.
  switch(scale,
         "county" = fips_counties_from_statefips(fips_area),
         "blockgroup" = fips_bgs_in_fips(fips_area),
         fips_area # Default to returning the original FIPS if the scale is not recognized.
  )
}

# The ejamit_interface function serves as a unified interface for the ejamit function,
# handling various input methods such as latitude/longitude, shapes (SHP), and FIPS codes.
ejamit_interface <- function(area, method, buffer = 0, scale = "blockgroup", endpoint="report") {
  # Validate buffer size to ensure it's within a reasonable limit.
  if (!is.numeric(buffer) || buffer > 15) {
    stop("Please select a buffer of 15 miles or less.")
  }
  
  # Process the request based on the specified method.
  switch(method,
         "latlon" = {
           # Ensure the area is a data frame before passing it to ejamit.
           if (!is.data.frame(area)) {
             stop("Invalid coordinates provided.")
           }
           ejamit(sitepoints = area, radius = buffer)
         },
         "SHP" = {
           # Convert the GeoJSON input to an sf object.
           sf_area <- tryCatch(
             geojson_sf(area),
             error = function(e) stop("Invalid GeoJSON provided.")
           )
           ejamit(shapefile = sf_area, radius = buffer)
         },
         "FIPS" = {
           # Process the FIPS code using the fipper function.
           if (endpoint == "data"){
             fips_codes <- fipper(area = area, scale = scale)
           } else if (endpoint == "report") {
             fips_codes <- area
           }
           ejamit(fips = fips_codes, radius = buffer)
         },
         stop("Invalid method specified.") # Handle unrecognized methods.
  )
}

#* CORS support so browser apps (e.g. EJScreen) can fetch()/POST cross-origin.
#* The single-site report flow uses a top-level window.open() GET and needs no
#* CORS, but the /handoff POST and any future POST endpoints do. Public data API,
#* so origin is open; tighten to specific origins here if ever needed.
#* @filter cors
function(req, res) {
  res$setHeader("Access-Control-Allow-Origin", "*")
  if (identical(req$REQUEST_METHOD, "OPTIONS")) {
    # Respond to the CORS preflight request directly.
    res$setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    res$setHeader(
      "Access-Control-Allow-Headers",
      req$HTTP_ACCESS_CONTROL_REQUEST_HEADERS %||% "Content-Type"
    )
    res$status <- 200L
    return(list())
  }
  plumber::forward()
}

#* Return EJAM analysis data as JSON based on geography
#* @param sites A data frame of site coordinates (lat/lon)
#* @param shape A GeoJSON string representing the area of interest
#* @param fips A FIPS code for a specific US Census geography
#* @param buffer The buffer radius in miles
#* @param geometries A boolean to indicate whether to include geometries in the output
#* @param scale The Census geography at which to return results (blockgroup or county)
#* @post /data
function(sites = NULL, shape = NULL, fips = NULL, buffer = 0, geometries = FALSE, scale = NULL, res) {
  # Determine the input method.
  method <- if (!is.null(sites)) "latlon" else if (!is.null(shape)) "SHP" else if (!is.null(fips)) "FIPS" else NULL
  area <- sites %||% shape %||% fips
  
  if (is.null(method) || is.null(area)) {
    res$status <- 400
    return(handle_error("You must provide valid points, a shape, or a FIPS code."))
  }
  
  # Perform the EJAM analysis.
  result <- tryCatch(
    ejamit_interface(area = area, method = method, buffer = as.numeric(buffer), scale = scale, endpoint = "data"),
    error = function(e) {
      res$status <- 400
      handle_error(e$message)
    }
  )
  
  # If an error was returned from the interface, return it.
  if ("error" %in% names(result)) {
    return(result)
  }
  
  # Prepare the final JSON output.
  if (geometries) {
    output_shape <- switch(method,
                           "latlon" = sf::st_as_sf(sites, coords = c("lon", "lat"), crs = 4326),
                           "SHP" = geojson_sf(shape),
                           "FIPS" = shapes_from_fips(fips)
    )
    # Combine the analysis results with the geographic shapes.
    return(cbind(data.table::setDF(result$results_bysite), output_shape))
  } else {
    return(result$results_bysite)
  }
}

#* Return EJAM analysis data as JSON based on attribute query
#* @param attribute An EJSCREEN attribute, in EJAM syntax (e.g. pctunemployed)
#* @param value A decimal, 0-1, representing a cutoff/threshold; returns blockgroups whose percentile rank for the attribute is larger (e.g. pctunemployed > .9)
#* @post /query
function(attribute = "pctunemployed", value=.9, res) {
  value <- suppressWarnings(as.numeric(value))
  if (length(value) != 1 || is.na(value) || value < 0 || value > 1) {
    res$status <- 400
    return(handle_error("value must be a numeric cutoff from 0 to 1."))
  }
  these <- pctile_x_is_hit_by_score(attribute, cutoff = value)
  results <- blockgroupstats[these,]
  return (results)
}

#* Generate an EJAM report
#* @param lat Latitude of the site
#* @param lon Longitude of the site
#* @param shape A GeoJSON string representing the area of interest
#* @param fips A FIPS code for a specific US Census geography
#* @param buffer The buffer radius in miles
#* @param sitenumber Which site to report on. Defaults to 1 (single-site). Use 0 (or "overall") for an aggregate MULTISITE report across all sites.
#* @param fileextension Whether to return a PDF or HTML file. Defaults to PDF.
#* @serializer contentType list(type = "application/octet-stream")
#* @get /report
function(lat = NULL, lon = NULL, shape = NULL, fips = NULL, buffer = 3, sitenumber=1, fileextension="pdf", res) {
  # Determine the input method and prepare the area.
  method <- if (!is.null(lat) && !is.null(lon)) "latlon" else if (!is.null(shape)) "SHP" else if (!is.null(fips)) "FIPS" else NULL

  # Multisite support: lat/lon and fips may be comma-separated lists, one site
  # each. Splitting here lets the same endpoint serve single-site (one value)
  # and multisite (several values) requests. Each FIPS code is a separate site
  # (no fipper() expansion), so a list of counties reports as a list of counties.
  area <- switch(
    method %||% "",
    "latlon" = data.frame(
      lat = as.numeric(trimws(strsplit(paste(lat, collapse = ","), ",")[[1]])),
      lon = as.numeric(trimws(strsplit(paste(lon, collapse = ","), ",")[[1]]))
    ),
    "FIPS" = trimws(strsplit(paste(fips, collapse = ","), ",")[[1]]),
    "SHP" = shape,
    NULL
  )

  if (is.null(method) || is.null(area)) {
    res$status <- 400
    return(handle_error("You must provide valid coordinates, a shape, or a FIPS code.", "html"))
  }

  # Normalize sitenumber. 0 or "overall" -> aggregate multisite report
  # (ejam2report renders results_overall); otherwise a single site.
  sitenum <- if (tolower(as.character(sitenumber)) %in% c("0", "overall")) 0 else suppressWarnings(as.numeric(sitenumber))
  if (is.na(sitenum)) sitenum <- 1

  # Perform the EJAM analysis.
  result <- tryCatch(
    ejamit_interface(area = area, method = method, buffer = as.numeric(buffer), endpoint="report"),
    error = function(e) {
      res$status <- 400
      handle_error(e$message, "html")
    }
  )
  
  # If an error occurred during the analysis, return the error message.
  if (is.character(result)) {
    return(result)
  }
  
  # Get submitted polygon shape(s) to appear in report map.
  to_map<-NULL # Clear any previous maps
  if (method == "SHP"){
    to_map<-geojson_sf(area) # TBD: get this returned from ejamit_interface
    to_map$ejam_uniq_id <- seq_len(nrow(to_map)) # one id per feature (multisite-safe)
  }

  # Generate and return the report.
  ext <- tolower(fileextension)
  rpt_title <- if (sitenum == 0) "EJSCREEN Multisite Report" else "EJSCREEN Community Report"
  report_output <- ejam2report(result, sitenumber = sitenum, return_html = (ext == "html"), launch_browser = FALSE, site_method = method, shp=to_map,
    report_title=rpt_title, fileextension=ext)

  if (ext == "html") {
    res$setHeader("Content-Type", "text/html")
    res$body <- report_output
    return(res)
  } 
  
  if (ext == "pdf") {
    # If report_output is a file path, we read it as RAW binary
    if (is.character(report_output) && file.exists(report_output)) {
      
      res$setHeader("Content-Type", "application/pdf")
      res$setHeader("Content-Disposition", "inline; filename=ejscreen_report.pdf")
      
      # Read the file as raw binary data to avoid 'embedded nul' issues
      file_size <- file.info(report_output)$size
      res$body <- readBin(report_output, "raw", n = file_size)
      
      # Clean up the temp file after reading it into memory
      on.exit(unlink(report_output), add = TRUE)
      
      return(res)
    } else {
      # If ejam2report already returned raw bytes, just pass them through
      res$setHeader("Content-Type", "application/pdf")
      res$body <- report_output
      return(res)
    }
  }
}

# ---- Site handoff (token-based) for launching the EJAM app pre-loaded ----
# An external app (e.g. EJScreen) POSTs a set of selected places and gets back a
# short token; it then opens the EJAM app at  ...?handoff=<token>  and the app
# fetches GET /handoff/<token> to pre-load those places. This avoids URL-length
# limits when handing off polygons.
#
# NOTE: this draft uses a simple in-process store with a TTL. On Cloud Run with
# more than one instance, a token created on instance A may not resolve on
# instance B. For production use a shared store (GCS object / Firestore / Redis)
# or run the service with min-instances=1 and a single max instance.
.handoff_store    <- new.env(parent = emptyenv())
.handoff_ttl_secs <- 60 * 60  # tokens live for 1 hour

.handoff_new_token <- function() {
  paste(sample(c(0:9, letters), 24, replace = TRUE), collapse = "")
}
.handoff_purge_expired <- function() {
  now <- as.numeric(Sys.time())
  for (k in ls(.handoff_store)) {
    if (.handoff_store[[k]]$expires < now) rm(list = k, envir = .handoff_store)
  }
}

#* Store a set of selected sites for handoff to the EJAM app; returns a token.
#* @param method One of "latlon", "FIPS", or "SHP" (optional; inferred if omitted)
#* @param sites Array of {lat, lon} site objects
#* @param fips Array of FIPS codes (each one a separate site)
#* @param shape A GeoJSON FeatureCollection of polygons
#* @param radius Buffer radius in miles
#* @post /handoff
function(method = NULL, sites = NULL, fips = NULL, shape = NULL, radius = NULL, res) {
  .handoff_purge_expired()
  if (is.null(sites) && is.null(fips) && is.null(shape)) {
    res$status <- 400
    return(handle_error("Provide sites, fips, or shape to hand off."))
  }
  if (is.null(method)) {
    method <- if (!is.null(sites)) "latlon" else if (!is.null(shape)) "SHP" else "FIPS"
  }
  token   <- .handoff_new_token()
  expires <- as.numeric(Sys.time()) + .handoff_ttl_secs
  .handoff_store[[token]] <- list(
    payload = list(method = method, sites = sites, fips = fips, shape = shape, radius = radius),
    expires = expires
  )
  list(token = token, expires = expires)
}

#* Retrieve a previously stored handoff payload by token.
#* @param token The handoff token returned by POST /handoff
#* @get /handoff/<token>
function(token, res) {
  .handoff_purge_expired()
  entry <- .handoff_store[[token]]
  if (is.null(entry)) {
    res$status <- 404
    return(handle_error("Unknown or expired handoff token."))
  }
  entry$payload
}

#* Serve static assets from the ./assets directory
#* @assets ./assets /
list()
