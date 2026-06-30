# Load necessary libraries
library(rlang)
library(plumber)
library(EJAM)
library(geojsonsf)
library(jsonlite)
library(sf)

############################# #
#* @apiTitle API for EJAM / EJSCREEN Data, Analysis, and Reports
#*
#* @apiDescription EJSCREEN provides environmental justice screening and mapping.
#* EJSCREEN's Multisite Tool is called EJAM (Environmental Justice Analysis Multisite).
#* For information about EJSCREEN, see <https://public-environmental-data-partners.github.io/EJAM/articles/ejscreen.html>.
#* For technical documentation on EJAM (software powering the API) see
#* <https://ejanalysis.org/ejamdocs>.
#* For information on the API itself, see
#* <https://github.com/Public-Environmental-Data-Partners/EJAM-API#ejam-api>
############################# #

# Centralized error handling function
handle_error <- function(message, type = "json") {
  if (type == "html") {
    return(paste0("<html><body><h3>Error</h3><p>", message, "</p></body></html>"))
  }
  return(list(error = message))
}

# Write an HTML error page to the response with the right status and an
# explicit text/html Content-Type, then return the response object. The
# /report endpoints use an octet-stream @serializer (so finished report bytes
# pass through untouched); returning a bare string there would label these
# error pages as application/octet-stream and make browsers download them.
# Returning the response object with Content-Type set -- as report_response()
# does for successful reports -- delivers the error as a viewable page.
html_error <- function(res, status, message) {
  res$status <- status
  res$setHeader("Content-Type", "text/html")
  res$body <- handle_error(message, "html")
  res
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

# ________________________________ ####
# Docs ####

#* Redirect the API root to the interactive documentation page, so visiting the
#* base URL (no endpoint or parameters) shows the Swagger UI.
#* @tag Docs
#* @get /
function(res) {
  res$status <- 302L
  res$setHeader("Location", "/__docs__/")
  list()
}

# /data ####

#* Return EJAM analysis data as JSON based on geography
#* @tag Data
#* @param sites A data frame of site coordinates (lat/lon)
#* @param shape A GeoJSON string representing the area of interest
#* @param fips A FIPS code for a specific US Census geography
#* @param buffer The buffer radius in miles
#* @param radius Synonym for buffer.
#* @param geometries A boolean to indicate whether to include geometries in the output
#* @param scale The Census geography at which to return results (blockgroup or county)
#* @post /data
function(sites = NULL, shape = NULL, fips = NULL, buffer = 0, radius = NULL, geometries = FALSE, scale = NULL, res) {
  if (!is.null(radius)) {buffer <- radius}  # radius is a synonym (alias) for buffer
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

# /query ####

#* Return EJAM analysis data as JSON based on attribute query
#* @tag Data
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

# /report ####

# Render an ejamit() result as an EJAM report and write it to the plumber
# response as HTML or PDF. Shared by GET /report (one value per param) and
# POST /report (JSON body; supports many/large polygons and mixed/large sets).
# report_title is intentionally left unset so ejam2report() picks the correct
# header by sitenumber ("EJSCREEN Community Report" vs "EJSCREEN Multisite Summary").
report_response <- function(result, method, to_map, sitenum, ext, res) {
  ext <- tolower(ext)
  if (!ext %in% c("html", "pdf")) {
    res$status <- 400
    res$setHeader("Content-Type", "text/html")
    res$body <- handle_error("fileextension must be 'html' or 'pdf'.", "html")
    return(res)
  }
  report_output <- ejam2report(result, sitenumber = sitenum, return_html = (ext == "html"),
    launch_browser = FALSE, site_method = method, shp = to_map, fileextension = ext)

  if (ext == "html") {
    res$setHeader("Content-Type", "text/html")
    res$body <- report_output
    return(res)
  }

  # PDF (default). ejam2report() returns a file path or raw bytes.
  if (is.character(report_output) && file.exists(report_output)) {
    res$setHeader("Content-Type", "application/pdf")
    res$setHeader("Content-Disposition", "inline; filename=ejscreen_report.pdf")
    file_size <- file.info(report_output)$size
    res$body <- readBin(report_output, "raw", n = file_size)
    on.exit(unlink(report_output), add = TRUE)
    return(res)
  }
  res$setHeader("Content-Type", "application/pdf")
  res$body <- report_output
  res
}

#* Generate an EJAM report
#* @tag Reports
#* @param lat Latitude of the site
#* @param lon Longitude of the site
#* @param shape A GeoJSON string representing the area of interest
#* @param fips A FIPS code for a specific US Census geography
#* @param buffer The buffer radius in miles
#* @param radius Synonym for buffer.
#* @param sitenumber Which site to report on. Defaults to 1 (single-site). Use 0 (or "overall") for an aggregate MULTISITE report across all sites.
#* @param fileextension Whether to return a PDF or HTML file. Defaults to PDF.
#* @serializer contentType list(type = "application/octet-stream")
#* @get /report
function(lat = NULL, lon = NULL, shape = NULL, fips = NULL, buffer = 3, radius = NULL, sitenumber=1, fileextension="pdf", res) {
  if (!is.null(radius)) {buffer <- radius}  # radius is a synonym (alias) for buffer
  # Determine the input method and prepare the area.
  method <- if (!is.null(lat) && !is.null(lon)) "latlon" else if (!is.null(shape)) "SHP" else if (!is.null(fips)) "FIPS" else NULL

  # Multisite support: lat/lon and fips may be comma-separated lists, one site
  # each. Splitting here lets the same endpoint serve single-site (one value)
  # and multisite (several values) requests. Each FIPS code is a separate site
  # (no fipper() expansion), so a list of counties reports as a list of counties.
  # Parse + validate lat/lon up front so mismatched counts fail cleanly (a 400)
  # instead of silently recycling (e.g. lat=33 & lon=-112,-114) or erroring 500.
  latv <- NULL; lonv <- NULL
  if (identical(method, "latlon")) {
    latv <- as.numeric(trimws(strsplit(paste(lat, collapse = ","), ",")[[1]]))
    lonv <- as.numeric(trimws(strsplit(paste(lon, collapse = ","), ",")[[1]]))
    if (anyNA(latv) || anyNA(lonv)) {
      return(html_error(res, 400, "lat and lon must contain only numeric comma-separated values."))
    }
    if (length(latv) != length(lonv)) {
      return(html_error(res, 400, "lat and lon must have the same number of comma-separated values."))
    }
  }
  area <- switch(
    method %||% "",
    "latlon" = data.frame(lat = latv, lon = lonv),
    "FIPS" = trimws(strsplit(paste(fips, collapse = ","), ",")[[1]]),
    "SHP" = shape,
    NULL
  )

  if (is.null(method) || is.null(area)) {
    return(html_error(res, 400, "You must provide valid coordinates, a shape, or a FIPS code."))
  }

  # Normalize sitenumber. 0 or "overall" -> aggregate multisite report
  # (ejam2report renders results_overall); otherwise a single site.
  sitenum <- if (tolower(as.character(sitenumber)) %in% c("0", "overall")) 0 else suppressWarnings(as.numeric(sitenumber))
  if (is.na(sitenum)) sitenum <- 1

  # Perform the EJAM analysis.
  result <- tryCatch(
    ejamit_interface(area = area, method = method, buffer = as.numeric(buffer), endpoint="report"),
    error = function(e) e
  )

  # If an error occurred during the analysis, return it as an HTML page.
  if (inherits(result, "error")) {
    return(html_error(res, 400, conditionMessage(result)))
  }
  
  # Get submitted polygon shape(s) to appear in report map.
  to_map<-NULL # Clear any previous maps
  if (method == "SHP"){
    to_map<-geojson_sf(area) # TBD: get this returned from ejamit_interface
    to_map$ejam_uniq_id <- seq_len(nrow(to_map)) # one id per feature (multisite-safe)
  }

  # Generate and return the report (HTML or PDF). See report_response() above.
  report_response(result, method, to_map, sitenum, tolower(fileextension), res)
}

#* Generate an EJAM report from a POST body (supports many/large polygons and mixed/large site sets).
#* Same report engine as GET /report, but inputs travel in the request body so there is no URL-length limit.
#* @tag Reports
#* @param sites An array of {lat, lon} site objects
#* @param shape A GeoJSON FeatureCollection string (one or more polygons)
#* @param fips An array of FIPS codes (each one a separate site)
#* @param buffer The buffer radius in miles (out from a polygon edge, or around a point)
#* @param radius Synonym for buffer.
#* @param sitenumber Which site to report on. Defaults to 0 = aggregate MULTISITE report across all sites.
#* @param fileextension "pdf" (default) or "html"
#* @serializer contentType list(type = "application/octet-stream")
#* @post /report
function(sites = NULL, shape = NULL, fips = NULL, buffer = 0, radius = NULL, sitenumber = 0, fileextension = "pdf", res) {
  if (!is.null(radius)) {buffer <- radius}  # radius is a synonym (alias) for buffer
  # One method per analysis; require exactly one input so an ambiguous request
  # (e.g. both sites and fips) fails cleanly instead of silently picking one.
  if (sum(!is.null(sites), !is.null(shape), !is.null(fips)) != 1) {
    return(html_error(res, 400, "Provide exactly one of sites, shape, or fips."))
  }
  method <- if (!is.null(sites)) "latlon" else if (!is.null(shape)) "SHP" else "FIPS"
  area <- sites %||% shape %||% fips

  # 0 or "overall" -> aggregate multisite report; otherwise the chosen single site.
  sitenum <- if (tolower(as.character(sitenumber)) %in% c("0", "overall")) 0 else suppressWarnings(as.numeric(sitenumber))
  if (is.na(sitenum)) sitenum <- 0

  result <- tryCatch(
    ejamit_interface(area = area, method = method, buffer = as.numeric(buffer), endpoint = "report"),
    error = function(e) e
  )
  if (inherits(result, "error")) {
    return(html_error(res, 400, conditionMessage(result)))
  }

  # Submitted polygon(s) to appear in the report map.
  to_map <- NULL
  if (method == "SHP") {
    to_map <- geojson_sf(area)
    to_map$ejam_uniq_id <- seq_len(nrow(to_map))
  }

  report_response(result, method, to_map, sitenum, tolower(fileextension), res)
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
.handoff_env_numeric_or_default <- function(name, default_value) {
  val <- suppressWarnings(as.numeric(Sys.getenv(name, as.character(default_value))))
  if (!is.finite(val) || val <= 0) {
    return(default_value)
  }
  val
}
.handoff_max_tokens <- .handoff_env_numeric_or_default("HANDOFF_MAX_TOKENS", 64)
.handoff_max_payload_bytes <- .handoff_env_numeric_or_default("HANDOFF_MAX_PAYLOAD_BYTES", 1048576)  # 1 MiB
.handoff_token_collision_retries <- as.integer(.handoff_env_numeric_or_default("HANDOFF_TOKEN_COLLISION_RETRIES", 8))

.handoff_new_token <- function() {
  # Tokens are bearer credentials, so REQUIRE a cryptographically-secure RNG --
  # fail fast rather than silently fall back to a guessable token.
  if (!requireNamespace("openssl", quietly = TRUE)) {
    stop("The 'openssl' package is required to mint secure handoff tokens.")
  }
  paste(as.character(openssl::rand_bytes(18)), collapse = "")  # 36 hex chars, CSPRNG
}
.handoff_purge_expired <- function() {
  now <- as.numeric(Sys.time())
  for (k in ls(.handoff_store)) {
    if (.handoff_store[[k]]$expires < now) {
      rm(list = k, envir = .handoff_store)
    }
  }
}

#* Store a set of selected sites for handoff to the EJAM app; returns a token.
#* @tag Handoff
#* @param method One of "latlon", "FIPS", or "SHP" (optional; inferred if omitted)
#* @param sites Array of {lat, lon} site objects
#* @param fips Array of FIPS codes (each one a separate site)
#* @param shape A GeoJSON FeatureCollection of polygons
#* @param radius Buffer radius in miles
#* @param buffer Synonym for radius.
#* @post /handoff
function(method = NULL, sites = NULL, fips = NULL, shape = NULL, radius = NULL, buffer = NULL, res) {
  if (is.null(radius)) {radius <- buffer}  # buffer is a synonym (alias) for radius
  .handoff_purge_expired()
  if (is.null(sites) && is.null(fips) && is.null(shape)) {
    res$status <- 400
    return(handle_error("Provide sites, fips, or shape to hand off."))
  }
  if (is.null(method)) {
    method <- if (!is.null(sites)) "latlon" else if (!is.null(shape)) "SHP" else "FIPS"
  }
  if (is.finite(.handoff_max_tokens) && length(ls(.handoff_store)) >= .handoff_max_tokens) {
    res$status <- 429
    return(handle_error(sprintf("Handoff token capacity reached (max %d active tokens). Retry after a short delay; tokens expire after 1 hour.", as.integer(.handoff_max_tokens))))
  }
  payload <- list(method = method, sites = sites, fips = fips, shape = shape, radius = radius)
  payload_raw <- serialize(payload, connection = NULL)
  payload_bytes <- length(payload_raw)
  if (is.finite(.handoff_max_payload_bytes) && payload_bytes > .handoff_max_payload_bytes) {
    res$status <- 413
    return(handle_error(sprintf("Handoff payload size %d bytes exceeds limit of %d bytes.", payload_bytes, as.integer(.handoff_max_payload_bytes))))
  }
  token <- NULL
  for (attempt in seq_len(.handoff_token_collision_retries)) {
    candidate <- .handoff_new_token()
    if (is.null(.handoff_store[[candidate]])) {
      token <- candidate
      break
    }
  }
  if (is.null(token)) {
    res$status <- 503
    return(handle_error("Unable to mint a unique handoff token; retry request."))
  }
  expires <- floor(as.numeric(Sys.time())) + .handoff_ttl_secs  # integer epoch seconds
  .handoff_store[[token]] <- list(
    payload_raw = payload_raw,
    expires = expires
  )
  # The token is a bearer credential -- don't let it sit in shared/proxy caches.
  res$setHeader("Cache-Control", "no-store")
  list(token = token, expires = expires)
}

#* Retrieve a previously stored handoff payload by token.
#* @tag Handoff
#* @param token The handoff token returned by POST /handoff
#* @get /handoff/<token>
function(token, res) {
  .handoff_purge_expired()
  entry <- .handoff_store[[token]]
  if (is.null(entry)) {
    res$status <- 404
    return(handle_error("Unknown or expired handoff token."))
  }
  res$setHeader("Cache-Control", "no-store")  # bearer-credential payload, not cacheable
  unserialize(entry$payload_raw)
}

# /assets ####

#* Serve static assets from the ./assets directory at /assets.
#* NOTE: do NOT mount at root "/", which shadows plumber's OpenAPI/Swagger
#* docs UI at /__docs__/ and makes the documentation page return 404.
#* @assets ./assets /assets
list()
