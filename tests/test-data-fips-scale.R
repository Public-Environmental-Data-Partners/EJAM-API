library(testthat)

# /data with fips: the optional `scale` (EJAM#764). Runs the real route and
# fipper() bodies with EJAM's FIPS helpers and ejamit() replaced by stubs, so no
# EJAM data is loaded.
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
post_data <- Filter(function(f) "geometries" %in% names(formals(f)), routes)[[1]]
new_response <- function() {
  res <- new.env()
  res$status <- 200L
  res
}

# Stubs: "10" is a state with counties 10001/10003/10005; "10001" is a county
# with two block groups.
api$name2fips <- function(x) {warning("not a name"); x}
api$fipstype <- function(x) ifelse(nchar(x) == 2, "state", ifelse(nchar(x) == 5, "county", "blockgroup"))
api$fips_counties_from_statefips <- function(x) c("10001", "10003", "10005")
api$fips_bgs_in_fips <- function(x) c("100010401001", "100010401002")
api$ejamit <- function(fips = NULL, radius, ...) {
  api$analyzed <- fips
  list(results_bysite = data.frame(ejam_uniq_id = fips))
}

test_that("fips without scale analyzes the area as given (was: 'argument is of length zero')", {
  res <- new_response()
  out <- post_data(fips = "10001", res = res)
  expect_identical(res$status, 200L)
  expect_identical(api$analyzed, "10001")
  for (blank in list(NULL, "", NA)) {
    expect_identical(api$fipper("10001", blank), "10001")
  }
})

test_that("scale county and blockgroup still expand the area", {
  post_data(fips = "10", scale = "county", res = new_response())
  expect_identical(api$analyzed, c("10001", "10003", "10005"))
  post_data(fips = "10001", scale = " County ", res = new_response())
  expect_identical(api$analyzed, "10001")
  post_data(fips = "10001", scale = "blockgroup", res = new_response())
  expect_identical(api$analyzed, c("100010401001", "100010401002"))
})

test_that("an unknown scale is a clear 400", {
  res <- new_response()
  out <- post_data(fips = "10001", scale = "tract", res = res)
  expect_identical(res$status, 400)
  expect_match(unlist(out$error), 'scale must be "blockgroup" or "county"')
})
