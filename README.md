<img src="man/figures/logo.png" align="right" height="139" alt="viyar hex logo" />

**Work with SAS Viya from R**

`viyar` addresses the missing piece in the R – SAS Viya integration:

|            | CAS | Compute (SAS code, PROCs) | Runtime deps |
|------------|-----|---------------------------|--------------|
| swat (R)   | yes | no                        | R             |
| saspy      | via Compute Session | yes                   | Python        |
| sasr       | via saspy | yes                   | Python + reticulate |
| **viyar**  | via Compute Session | **yes** | **R** |

## Quick start

### Inside Posit Workbench

If Workbench has a Viya OAuth integration configured, `viyar` auto-detects
both the token and the Viya server URL — getting a session is one line,
no `viya_config()` or login step needed:

```r
library(viyar)
h <- viya_session()
viya_librefs(h)
```

### Anywhere else (local desktop R, Posit Connect, CI)

```r
viya_config(url = "https://your-viya-server.example.com")
# token: VIYA_TOKEN env var, or viya_login() for an interactive SSO login

h <- viya_session()                    # compute session (retry/reachability aware)
viya_librefs(h)
r <- viya_submit(h, "cas m; caslib _all_ assign;")
viya_librefs(h)                        # now includes PUBLIC, CASUSER, ...

heart <- viya_read(h, "PUBLIC", "HEART")     # SAS/CAS -> R
adsl  <- viya_read(h, "WORK", "ADSL", dates = "TRTSDT")  # SAS dates -> Date
viya_write(h, subset(heart, Cholesterol > 300), "WORK", "HIGH_CHOL")

viya_caslib_tables(h, "Public")        # loaded / unloaded states
viya_caslib_files(h, "Public")         # source files on disk
viya_load_table(h, "Public", "orders.sashdat", promote = TRUE)

viya_upload(h, "report.html", "/Public")
viya_end(h)
```

## Submitting SAS code

`viya_submit()` returns the log by default. Ask for the listing (LST
text) or the ODS HTML with `output`:

```r
r <- viya_submit(h, code, output = c("log", "listing", "html"))
r$log        # character vector of log lines
r$listing    # character vector of listing lines
r$html       # character vector of HTML documents, named by ODS object
```

Each kind costs extra requests, so `viyar` fetches only what you ask
for. The default, `output = "log"`, behaves as before.

`viyar` does not add ODS statements to your code. A destination
produces output only when your own code opens it, and a compute server
starts with `ods listing` closed:

```r
r <- viya_submit(h, "ods listing;
                     proc print data=sashelp.class(obs=5); run;
                     ods listing close;",
                 output = "listing")
cat(r$listing, sep = "\n")
```

For HTML, open an `html5` destination with no `file=`. The compute
server then routes the output to its results endpoint, where `viyar`
can download it. Giving it an explicit `file=` writes to the compute
server's own disk instead, where the results endpoint never sees it:

```r
r <- viya_submit(h, "ods html5(id=viyar);
                     proc means data=sashelp.class; run;
                     ods html5(id=viyar) close;",
                 output = "html")
writeLines(r$html[[1]], "means.html")
```

`r$html` is named for the files the server generated (`sashtml.htm`,
`sashtml1.htm`, ...), not for the procedures that produced them.

## Folders and files

Two separate storage systems, two separate function families:

- **SAS Content** (the Files/Folders app in Viya): `viya_create_folder()`,
  `viya_upload()`, `viya_download()`, `viya_delete_file()`,
  `viya_delete_folder()`.
- **The compute session's own filesystem** (a home directory, an
  NFS-mounted shared path, or anything else the session process can see
  on disk): `viya_fs_mkdir()`, `viya_fs_upload()`, `viya_fs_download()`,
  `viya_fs_list()`, `viya_fs_delete()`. These need an active compute
  session (`h`) and operate on that session's real filesystem, not the
  Files/Folders app. Note that a path can be readable without being
  writable (e.g. an NFS-mounted home directory with restrictive
  permissions) — `/tmp` is a reliable writable scratch location if you
  hit unexpected 404s on `viya_fs_mkdir()`/`viya_fs_upload()`.

```r
viya_create_folder(h, "/Public/Reports/2026")
viya_upload(h, "report.html", "/Public/Reports/2026")
viya_delete_file(h, "/Public/Reports/2026/report.html")
viya_delete_folder(h, "/Public/Reports/2026")

viya_fs_mkdir(h, "/nfs/homes/user/reports/2026")
viya_fs_upload(h, "report.html", "/nfs/homes/user/reports/2026/report.html")
viya_fs_list(h, "/nfs/homes/user/reports/2026")
viya_fs_delete(h, "/nfs/homes/user/reports/2026")
```

## SAS Clinical Acceleration Repository

A third, separate storage system, available only on clusters licensed for
SAS Clinical Acceleration. It is a governed hierarchy — contexts
(organizations, studies, deliveries, ...) hold folders, which hold files
— and `viyar` reads it without a compute session, so these functions take
`token`/`url` rather than a handle `h`:

```r
viya_clinical_item()                    # the repository root
viya_clinical_list()                    # top-level contexts
viya_clinical_list("/Acme/Study 1")     # everything inside a study
viya_clinical_types()                   # what the type_id column means

viya_clinical_download("/Acme/Study 1/protocol.sas", "protocol.sas")
viya_clinical_download("/Acme/Study 1", "study1.zip")  # a container
utils::unzip("study1.zip", exdir = "study1")
```

`viya_clinical_list()` returns `name`, `id`, `type` (`CONTEXT`, `FOLDER`
or `FILE`), `type_id`, `path`, `size`, `state` and `modified`, and it
pages through the whole container rather than stopping at the first
page.

A file downloads as itself. A context or folder downloads as a **ZIP
archive** of everything under it. The service sends no file name either
way, so give `local_path` the full destination name. Writing to the
repository (creating contexts, uploading files) is out of scope here:
this release is read-only.

If you already have a compute session, reuse its credentials rather than
configuring them twice:

```r
h <- viya_session()
viya_clinical_list("/", token = h$token, url = h$base)
```

## Authenticating to SAS Viya

- Workbench: managed OAuth credentials via rstudioapi (integration name
  configurable, default `^sas-viya$`). The Viya URL is auto-detected from
  the integration if `viya_config(url = ...)`/`VIYA_URL` isn't set.
- Local desktop R (outside Workbench): `viya_login()` opens a browser SSO
  login (authorization code + PKCE) and caches the resulting token,
  refreshing it automatically as it nears expiry.
- Posit Connect: obtain a viewer token with connectapi and pass it:
  `viya_session(token = viewer_token)`.
- Anywhere: set `VIYA_TOKEN`.

## Installation

viyar is not on CRAN. Install it from GitHub:

```r
# install.packages("pak")
pak::pak("sol-eng/viyar")
```

Or with remotes:

```r
# install.packages("remotes")
remotes::install_github("sol-eng/viyar")
```

## License

MIT. See [LICENSE](LICENSE).
