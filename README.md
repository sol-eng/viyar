# viyar

**SAS Viya Compute + CAS integration for R — pure REST, no Python.**

The missing piece in the R–SAS ecosystem:

|            | CAS | Compute (SAS code, PROCs) | Runtime deps |
|------------|-----|---------------------------|--------------|
| swat (R)   | yes | no                        | R             |
| saspy      | via SAS | yes                   | Python        |
| sasr       | via SAS | yes                   | Python + reticulate |
| **viyar**  | management + load/promote | **yes** | **R only (httr2)** |

## Quick start

```r
viya_config(url = "https://your-viya-server.example.com")
# token: VIYA_TOKEN env var, or Posit Workbench managed credentials (auto)

h <- viya_session()                    # compute session (retry/reachability aware)
viya_librefs(h)
r <- viya_submit(h, "cas m; caslib _all_ assign;")
viya_librefs(h)                        # now includes PUBLIC, CASUSER, ...

heart <- viya_read(h, "PUBLIC", "HEART")     # SAS/CAS -> R
viya_write(h, subset(heart, Cholesterol > 300), "WORK", "HIGH_CHOL")

viya_caslib_tables(h, "Public")        # loaded / unloaded states
viya_caslib_files(h, "Public")         # source files on disk
viya_load_table(h, "Public", "orders.sashdat", promote = TRUE)

viya_upload(h, "report.html", "/Public")
viya_end(h)
```

## Auth

- Workbench: managed OAuth credentials via rstudioapi (integration name
  configurable, default `^sas-viya$`).
- Posit Connect: obtain a viewer token with connectapi and pass it:
  `viya_session(token = viewer_token)`.
- Anywhere: set `VIYA_TOKEN`.

## Install (development)

```r
# from a source checkout:
pkgload::load_all("viyar")     # or
devtools::install_local("viyar")
```
