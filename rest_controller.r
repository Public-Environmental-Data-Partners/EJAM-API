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
#* @param sitenumber Which site, in a multi-site analysis, to run a report for. Defaults to 1.
#* @param fileextension Whether to return a PDF or HTML file. Defaults to PDF.
#* @serializer contentType list(type = "application/octet-stream")
#* @get /report
function(lat = NULL, lon = NULL, shape = NULL, fips = NULL, buffer = 3, sitenumber=1, fileextension="pdf", res) {
  # Determine the input method and prepare the area.
  method <- if (!is.null(lat) && !is.null(lon)) "latlon" else if (!is.null(shape)) "SHP" else if (!is.null(fips)) "FIPS" else NULL
  area <- if (method == "latlon") data.frame(lat = as.numeric(lat), lon = as.numeric(lon)) else shape %||% fips
  
  if (is.null(method) || is.null(area)) {
    res$status <- 400
    return(handle_error("You must provide valid coordinates, a shape, or a FIPS code.", "html"))
  }
  
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
  
  # Get submitted polygon shape to appear in report map.
  to_map<-NULL # Clear any previous maps
  if (method == "SHP"){
    to_map<-geojson_sf(area) # TBD: get this returned from ejamit_interface
    to_map$ejam_uniq_id <- 1 # Might run into issues here for multisite reports
  }

  # Generate and return the report.
  ext <- tolower(fileextension)
  report_output <- ejam2report(result, sitenumber = sitenumber, return_html = (ext == "html"), launch_browser = FALSE, site_method = method, shp=to_map,
    report_title="EJSCREEN Community Report", fileextension=ext)

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

#* Serve static assets from the ./assets directory
#* @assets ./assets /
list()
