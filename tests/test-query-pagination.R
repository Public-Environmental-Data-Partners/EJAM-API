library(testthat)

source("query_pagination.R")

sample_results <- data.frame(
  bgid = sprintf("%03d", 1:12),
  pctlowinc = seq(0.91, 1.02, length.out = 12),
  stringsAsFactors = FALSE
)

test_that("query pagination returns the requested 1-based page with metadata", {
  payload <- paginate_query_results(sample_results, page = "2", limit = "5")

  expect_equal(payload$results$bgid, sprintf("%03d", 6:10))
  expect_equal(payload$pagination$page, 2L)
  expect_equal(payload$pagination$limit, 5L)
  expect_equal(payload$pagination$total_rows, 12L)
  expect_equal(payload$pagination$total_pages, 3L)
  expect_equal(payload$pagination$returned_rows, 5L)
  expect_true(payload$pagination$has_next_page)
  expect_true(payload$pagination$has_previous_page)
})

test_that("query pagination returns an empty page beyond available results", {
  payload <- paginate_query_results(sample_results, page = 4, limit = 5)

  expect_equal(nrow(payload$results), 0L)
  expect_equal(names(payload$results), names(sample_results))
  expect_equal(payload$pagination$page, 4L)
  expect_equal(payload$pagination$total_pages, 3L)
  expect_equal(payload$pagination$returned_rows, 0L)
  expect_false(payload$pagination$has_next_page)
  expect_true(payload$pagination$has_previous_page)
})

test_that("query pagination validates page and limit inputs", {
  expect_error(
    paginate_query_results(sample_results, page = 0, limit = 5),
    "page must be a positive whole number",
    fixed = TRUE
  )
  expect_error(
    paginate_query_results(sample_results, page = 1, limit = 501),
    "limit must be a positive whole number no larger than 500",
    fixed = TRUE
  )
  expect_error(
    paginate_query_results(sample_results, page = 1.5, limit = 5),
    "page must be a positive whole number",
    fixed = TRUE
  )
})

test_that("query endpoint response paginates selected EJAM rows", {
  selected <- c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, FALSE, FALSE)
  pctile_fun <- function(attribute, cutoff) {
    expect_equal(attribute, "pctlowinc")
    expect_equal(cutoff, 0.95)
    selected
  }
  res <- new.env(parent = emptyenv())

  payload <- query_endpoint_response(
    attribute = "pctlowinc",
    value = "0.95",
    page = 2,
    limit = 4,
    res = res,
    pctile_fun = pctile_fun,
    blockgroupstats_data = sample_results
  )

  expect_equal(payload$results$bgid, sprintf("%03d", 5:8))
  expect_equal(payload$pagination$total_rows, 10L)
  expect_equal(payload$pagination$total_pages, 3L)
  expect_null(res$status)
})

test_that("query endpoint response maps invalid inputs to 400 errors", {
  pctile_fun <- function(attribute, cutoff) rep(TRUE, nrow(sample_results))
  res <- new.env(parent = emptyenv())

  payload <- query_endpoint_response(
    attribute = "pctlowinc",
    value = "0.95",
    page = 1,
    limit = 501,
    res = res,
    pctile_fun = pctile_fun,
    blockgroupstats_data = sample_results
  )

  expect_equal(res$status, 400)
  expect_equal(payload$error, "limit must be a positive whole number no larger than 500.")
})
