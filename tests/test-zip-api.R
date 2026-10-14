library(testthat)

# Exercise the actual route bodies without loading EJAM data, downloading ZCTAs,
# or rendering PDFs. Only external analysis/rendering functions are replaced.
controller_file <- if (file.exists("rest_controller.r")) "rest_controller.r" else "../rest_controller.r"
controller <- parse(controller_file)
api <- new.env(parent = globalenv())
api$`%||%` <- function(x, y) if (is.null(x)) y else x
for (expr in controller) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
      is.call(expr[[3]]) && identical(expr[[3]][[1]], as.name("function"))) {
    eval(expr, api)
  }
}
routes <- lapply(Filter(function(expr) is.call(expr) && identical(expr[[1]], as.name("function")),
                        as.list(controller)), eval, envir = api)
get_report <- Filter(function(f) "lat" %in% names(formals(f)), routes)[[1]]
post_report <- Filter(function(f) all(c("sites", "fileextension") %in% names(formals(f))), routes)[[1]]
post_data <- Filter(function(f) "geometries" %in% names(formals(f)), routes)[[1]]
new_response <- function() {
  res <- new.env()
  res$status <- 200L
  res$headers <- list()
  res$setHeader <- function(name, value) res$headers[[name]] <- value
  res
}
api$ejamit <- function(zipcode = NULL, fips = NULL, radius, ...) {
  codes <- if (is.null(zipcode)) fips else zipcode
  list(zipcode = zipcode, radius = radius, fips = fips,
       results_bysite = data.frame(code = codes))
}
api$ejam2report <- function(result, sitenumber, site_method, fileextension, ...) {
  api$rendered <- list(result = result, sitenumber = sitenumber,
                       site_method = site_method, fileextension = fileextension)
  if (fileextension == "html") "<html>ZIP report</html>" else charToRaw("%PDF synthetic")
}

test_that("ZIP aliases normalize vectors, JSON arrays, comma lists, leading zeroes and ZIP+4", {
  for (input in list("10605, 01001", c("10605", "01001"), list(10605, 1001))) {
    expect_identical(api$normalize_zip_input(zip = input), c("10605", "01001"))
    expect_identical(api$normalize_zip_input(zipcode = input), c("10605", "01001"))
  }
  expect_identical(api$normalize_zip_input("10605-1234,106051234,1001"), c("10605", "01001"))
  expect_null(api$normalize_zip_input())
  for (bad in list("", character(), NA, "bad", "10605,bad", "123456", -10605, 10605.5)) {
    expect_error(api$normalize_zip_input(bad), "must contain ZIP codes")
  }
})

test_that("both report methods use ZIP boundaries, zero buffer and existing report selection", {
  for (route in list(get_report, post_report)) {
    for (alias in c("zip", "zipcode")) {
      res <- new_response()
      do.call(route, c(setNames(list("10605,01001"), alias), list(sitenumber = 0, res = res)))
      expect_identical(res$status, 200L)
      expect_identical(res$headers[["Content-Type"]], "text/html")
      expect_identical(api$rendered$site_method, "ZIP")
      expect_identical(api$rendered$result$zipcode, c("10605", "01001"))
      expect_equal(api$rendered$result$radius, 0)
      expect_equal(api$rendered$sitenumber, 0)
      route(zip = "10605,01001", radius = 1, sitenumber = 2, res = new_response())
      expect_equal(api$rendered$result$radius, 1)
      expect_equal(api$rendered$sitenumber, 2)
      expect_identical(api$rendered$fileextension, "pdf")
    }
  }
  get_report(zip = "10605", res = new_response())
  expect_equal(api$rendered$sitenumber, 1)
  post_report(zip = "10605", res = new_response())
  expect_equal(api$rendered$sitenumber, 0)
})

test_that("ZIP validation failures return HTTP 400 before analysis for all routes", {
  for (route in list(get_report, post_report, post_data)) {
    for (input in list(list(zip = "bad"), list(zip = ""),
                       list(zip = "10605", zipcode = "10605"),
                       list(zip = "10605", fips = "10001"),
                       list(zip = "10605", shape = "{}"))) {
      res <- new_response()
      output <- do.call(route, c(input, list(res = res)))
      expect_equal(res$status, 400)
      if (identical(route, post_data)) expect_true("error" %in% names(output))
      else expect_identical(res$headers[["Content-Type"]], "text/html")
    }
  }
  for (input in list(list(lat = 40), list(lon = -75), list(lat = 40, lon = -75))) {
    res <- new_response()
    do.call(get_report, c(list(zip = "10605", res = res), input))
    expect_equal(res$status, 400)
  }
  for (route in list(post_report, post_data)) {
    res <- new_response()
    route(zip = "10605", sites = list(list(lat = 40, lon = -75)), res = res)
    expect_equal(res$status, 400)
  }
})

test_that("data aliases reach ejamit and FIPS stays a separate geography", {
  for (alias in c("zip", "zipcode")) {
    output <- do.call(post_data, c(setNames(list(list(10605, 1001)), alias), list(res = new_response())))
    expect_identical(output$code, c("10605", "01001"))
    expect_identical(output$zipcode, output$code)
  }
  get_report(fips = "10001", res = new_response())
  expect_identical(api$rendered$site_method, "FIPS")
  expect_null(api$rendered$result$zipcode)
  expect_identical(api$rendered$result$fips, "10001")
  api$ejamit <- function(...) stop("No ZCTA polygons found")
  res <- new_response()
  output <- post_data(zip = "99999", res = res)
  expect_equal(res$status, 400)
  expect_match(output$error, "No ZCTA")
})

test_that("ZIP geometry output uses the codes actually analyzed, in result order", {
  skip_if_not_installed("data.table")
  api$ejamit <- function(...) list(zipcode = c("01001", "10605"),
                                 results_bysite = data.frame(code = c("01001", "10605")))
  api$shapes_from_zip <- function(zipcode) data.frame(zip = zipcode)
  output <- post_data(zip = "01001,99999,10605", geometries = TRUE, res = new_response())
  expect_identical(output$zip, output$code)
  expect_identical(output$zipcode, output$code)
  expect_equal(nrow(output), 2)
})

test_that("plumber exposes both aliases on all analysis routes", {
  for (pkg in c("EJAM", "plumber", "geojsonsf", "sf")) skip_if_not_installed(pkg)
  pr <- withr::with_dir(dirname(controller_file), plumber::plumb(basename(controller_file)))
  spec <- pr$getApiSpec()
  for (route in list(c("/report", "get"), c("/report", "post"), c("/data", "post"))) {
    params <- spec$paths[[route[1]]][[route[2]]]$parameters
    expect_true(all(c("zip", "zipcode") %in% vapply(params, `[[`, "", "name")))
  }
})
