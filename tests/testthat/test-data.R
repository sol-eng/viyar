.data_handle <- function() {
  structure(list(token = "t", session = "sess1", context = "ctx",
                 base = "https://viya.example.com"), class = "viyar")
}

# Serves the two endpoints `viya_read()` hits, dispatching on the URL.
# Only the first page of rows carries data, so a caller with fewer rows
# than `chunk` stops after one request.
#
# `rows` is a JSON string rather than an R list: a missing cell arrives
# from Viya as a literal `null`, and round-tripping one through
# `response_json()` would emit `{}` instead -- which the code under test
# handles differently from `null`, so the mock has to be exact about it.
.mock_data <- function(seen, cols, rows) {
  function(req) {
    seen$url <- c(seen$url, req$url)
    u <- req$url
    if (grepl("/columns", u))
      return(httr2::response_json(status = 200, body = list(items = cols)))
    if (grepl("/rows", u))
      return(httr2::response(
        status = 200, headers = list(`content-type` = "application/json"),
        body = charToRaw(if (grepl("start=0", u)) rows else '{"items":[]}')))
    stop("unexpected request: ", u)
  }
}

.cols_date_name <- list(
  list(name = "TRTSDT", type = "FLOAT"),
  list(name = "NAME", type = "CHAR"))

# 21915 is the SAS date value for 2020-01-01 (days since 1960-01-01).
.rows_date_name <-
  '{"items":[{"cells":[21915,"Alfred"]},{"cells":[null,"Alice"]}]}'

test_that("viya_read() asks the rows endpoint for unformatted values", {
  # The endpoint defaults to format=true, which returns display strings --
  # `as.numeric("01JAN2020")` is NA and `as.numeric("$1,234.50")` is NA.
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, .rows_date_name))

  suppressMessages(viya_read(h, "WORK", "ADSL"))

  expect_match(grep("/rows", seen$url, value = TRUE)[1], "format=false",
               fixed = TRUE)
})

test_that("viya_read(dates =) converts SAS day numbers to Date", {
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, .rows_date_name))

  df <- suppressMessages(viya_read(h, "WORK", "ADSL", dates = "TRTSDT"))

  expect_s3_class(df$TRTSDT, "Date")
  expect_equal(df$TRTSDT, as.Date(c("2020-01-01", NA)))
})

test_that("viya_read(dates =) matches column names case-insensitively", {
  # SAS preserves the case a column was defined with, so a caller working
  # from a CDISC spec types `TRTSDT` for a column the table calls `trtsdt`.
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(.mock_data(
    seen,
    list(list(name = "trtsdt", type = "FLOAT")),
    '{"items":[{"cells":[21915]}]}'))

  df <- suppressMessages(viya_read(h, "WORK", "ADSL", dates = "TRTSDT"))

  expect_equal(df$trtsdt, as.Date("2020-01-01"))
})

test_that("viya_read(dates =) errors on a column the table does not have", {
  # Silently ignoring a typo would reproduce the all-NA date bug this
  # argument exists to fix, only harder to spot.
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, .rows_date_name))

  expect_error(suppressMessages(viya_read(h, "WORK", "ADSL",
                                          dates = c("TRTSDT", "TRTEDT"))),
               "not found in WORK.ADSL: TRTEDT")
})

test_that("viya_read(dates =) errors on a character column", {
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, .rows_date_name))

  expect_error(suppressMessages(viya_read(h, "WORK", "ADSL",
                                          dates = "NAME")),
               "not numeric: NAME")
})

test_that("viya_read() types the columns of an empty table", {
  # An empty read used to return every column as character regardless of
  # its type, so `dates` was silently a no-op there -- code that branches
  # on the column class would take the wrong branch on a zero-row table.
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, '{"items":[]}'))

  df <- suppressMessages(viya_read(h, "WORK", "ADSL", dates = "TRTSDT"))

  expect_equal(nrow(df), 0)
  expect_s3_class(df$TRTSDT, "Date")
  expect_type(df$NAME, "character")
})

test_that("viya_read() leaves other columns alone when dates is given", {
  h <- .data_handle()
  seen <- new.env()
  httr2::local_mocked_responses(
    .mock_data(seen, .cols_date_name, .rows_date_name))

  df <- suppressMessages(viya_read(h, "WORK", "ADSL", dates = "TRTSDT"))

  expect_equal(df$NAME, c("Alfred", "Alice"))
})

# The other half of this bug -- a `10.4`-formatted numeric arriving
# truncated to 4 decimals -- is server-side formatting, so no mock can
# reproduce it honestly: a unit test would only assert that
# `as.numeric("60.2696")` is 60.2696. The `format=false` test above pins
# the fix; `test-live-data.R` asserts the precision itself.
