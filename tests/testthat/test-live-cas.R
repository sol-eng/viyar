# This test needs a Viya deployment whose CAS server is actually running
# (GET /casManagement/servers/{server}/state == "running") -- during
# development the primary test cluster's CAS backend was found stuck in
# "starting" with a DNS lookup failure for its pod, an environment issue
# unrelated to viyar's code. If this test 404s where the others in this
# directory pass, check that cluster's CAS state before assuming a
# regression; point VIYA_URL at a different deployment if needed.
test_that("caslib listing and load/unload round-trip", {
  skip_if_no_viya()
  h <- viya_session()
  on.exit(viya_end(h), add = TRUE)

  files <- viya_caslib_files(h, "Public")
  expect_true(all(c("name", "size") %in% names(files)))
  skip_if(nrow(files) == 0, "no source files in Public caslib to load")

  target <- files$name[1]
  viya_load_table(h, "Public", target, promote = FALSE)
  tables <- viya_caslib_tables(h, "Public")
  expect_true(all(c("name", "state") %in% names(tables)))

  casout <- toupper(sub("\\.[^.]+$", "", target))
  viya_unload_table(h, "Public", casout)
})
