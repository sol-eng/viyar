# Quarto `{sas}` chunk engine — design spec

## Purpose

Let a Quarto document (`.qmd`) submit SAS code to a Viya compute session
using a native-feeling `{sas}` fenced code block, instead of writing an R
chunk that manually calls `viya_submit()` and `cat()`s the log. This is a
new integration surface for hybrid clinical submission documents (R +
SAS in one rendered report), built entirely on `viyar`'s existing REST
primitives — no new REST calls, no new auth mechanism.

## Non-goals

- No automatic session lifecycle. The user starts and ends the compute
  session exactly as they do today (`h <- viya_session()` / `viya_end(h)`)
  in ordinary R chunks. The `{sas}` engine only ever *uses* a handle the
  user already created; it never creates or destroys one itself.
- No new credential-persistence mechanism for Positron Desktop. The
  existing `viya_token()` resolution chain (`VIYA_TOKEN` → cached token →
  Workbench managed OAuth → cached `viya_login()` SSO token) is unchanged
  and already handles both Workbench and Positron Desktop correctly, per
  `CLAUDE.md`'s existing auth section. Desktop users call `viya_login()`
  in their console before rendering, same as today.
- No ODS output for non-HTML Quarto targets (PDF/Typst/docx) in v1. ODS
  HTML can only be embedded as raw HTML, so it only renders correctly in
  HTML-family output formats — this mirrors `viya_submit()`'s own
  existing HTML-only ODS support, not a new limitation introduced here.
- No change to `viya_submit()` itself. This is deliberately a "new submit
  branch" — a separate function with separate semantics (fail-fast by
  default, knitr-renderable return shape) — layered on top of it.

## Mechanism: a knitr custom engine, auto-registered on load

`viyar` registers a knitr chunk engine named `"sas"` in `.onLoad()`,
guarded by `requireNamespace("knitr", quietly = TRUE)` (`knitr` becomes a
new `Suggests`, not a hard dependency — consistent with `rstudioapi`/
`connectapi` already being optional). Once `library(viyar)` runs in a
setup chunk, any ` ```{sas} ` block in the document is handled by
`viyar`.

This is the same extension point knitr's own built-in `sql` engine uses
(`knitr::knit_engines$set(sql = ...)`), so it is idiomatic rather than
novel plumbing, and other packages doing the same thing (e.g.
`SASmarkdown`) are precedent that this pattern works inside Quarto's
knitr execution model.

The compute session stays exactly as manual as it is today. A setup
chunk starts it; each `{sas}` chunk names that handle via a chunk
option, resolved as an R symbol looked up in the knit environment —
exactly how knitr's `sql` engine resolves its own `connection: con`
option:

````
```{r}
#| label: setup
library(viyar)
h <- viya_session()
```

```{sas}
#| session: h
proc means data=sashelp.class; run;
```

```{r}
#| label: cleanup
viya_end(h)
```
````

**Known limitation, not a blocker:** the engine name `"sas"` is not
reserved. If a document also loads `SASmarkdown` (which registers its
own `sas`/`saslog`/`sashtml` engines), whichever package calls
`knitr::knit_engines$set(sas = ...)` last wins. Worth a doc note, not
worth solving here.

## New function(s) and files

- **`R/zzz.R`** (new) — `.onLoad()`, registering the `sas` engine only if
  `knitr` is installed.
- **`R/quarto.R`** (new) — houses:
  - **`viya_submit_quarto(h, code, output = "html", poll_s = 1, timeout_s = 300)`**
    — exported. The new "submit branch." Calls the existing
    `viya_submit()` internally (no duplicated REST/polling logic) and
    adds the two behaviors that only make sense inside a rendered
    document:
    1. **Fail-fast**: throws a plain R error when the job's `state` is
       not `"completed"`. The error message includes the state and the
       last few log lines, so a render failure is diagnosable without
       re-running. (See "Error semantics" below for the
       sticky-error-state interaction.)
    2. Returns a shape the engine can render directly (state, and the
       requested output kinds, structured the same as `viya_submit()`'s
       own return value — no new return contract beyond the throw).
  - **`.viya_sas_engine(options)`** — the knitr engine callback (internal,
    not exported). Reads `options$session` (resolved to the handle
    object) and `options$code`, resolves the chunk options below, calls
    `viya_submit_quarto()`, and assembles the rendered output block.

### Chunk options

All optional except `session`.

| Option | Default | Meaning |
|---|---|---|
| `session` | *(required)* | R symbol naming the `viyar` handle (e.g. `h`) |
| `viya.output` | `"html"` | one or more of `"log"`, `"listing"`, `"html"` — deliberately namespaced: knitr/Quarto already define their own `output:` (show/hide chunk output), and reusing that name would collide with it |
| `viya.error` | `FALSE` | set `TRUE` to suppress the fail-fast throw for a chunk where a non-`"completed"` state is expected/acceptable |
| `echo` | `TRUE` | standard knitr option — shows the SAS source; no new option needed |
| `viya.poll_s` | `1` | passed through to `viya_submit()`'s `poll_s` |
| `viya.timeout_s` | `300` | passed through to `viya_submit()`'s `timeout_s` |

### Output rendering

- `"log"` / `"listing"` → a fenced, `echo`-respecting output block via
  `knitr::engine_output()` — identical treatment to an R chunk's console
  output.
- `"html"` → raw ODS HTML emitted via `knitr::asis_output()`. Only
  renders correctly in HTML-family Quarto targets. For PDF/Typst/docx,
  the documented alternative is `viya.output: "listing"`.

## Error semantics

`viya_submit_quarto()` trusts the job's own `state` field as-is (matching
`viya_submit()`'s existing behavior elsewhere in the package) and throws
whenever it isn't `"completed"`, unless `viya.error: true` is set on that
chunk.

This deliberately interacts with a known Viya behavior already
documented in `CLAUDE.md`: once one job in a compute session errors,
every *later* job in that same session reports state `"error"` too, even
with a clean log of its own. Because the engine's default is fail-fast,
this cascade is actually useful here, not confusing: rendering stops at
the *first* real failure and never reaches the falsely-flagged later
chunks at all. This reasoning is recorded here explicitly so it isn't
"fixed" by mistake later — the fail-fast default is what neutralizes the
caveat, not something working around it.

## Testing

Matches the project's existing two-tier convention:

- **Mocked unit tests** (`tests/testthat/test-quarto.R`): `viya_submit_quarto()`'s
  throw/no-throw branching (completed vs. error/failed/canceled state,
  with and without `viya.error`), and `.viya_sas_engine()`'s option
  resolution and output-assembly shape (log/listing fenced-block vs. html
  asis-block), all via `httr2::local_mocked_responses()`. No real knitr
  render is needed to test the adapter logic itself.
- **Live/manual check**: a full real `quarto render` of a `.qmd` using
  `{sas}` chunks, via the new example file below. Not part of the
  automated suite — consistent with `viya_session()`'s retry loop and
  `viya_submit()`'s poll loop already being live-only.

## Docs

- New dedicated example file: `examples/viyar-quarto-sas.qmd`, focused
  specifically on the `{sas}` engine (kept separate from the existing
  general workflow demo, `examples/viyar-workflow-demo.qmd`).
- A new `CLAUDE.md` entry for `R/quarto.R` and `R/zzz.R`, alongside the
  existing per-file architecture notes.
- roxygen docs for `viya_submit_quarto()`, including a `\dontrun{}`
  example mirroring `viya_submit()`'s own doc style.

## Open items for the implementation plan

- New `Suggests: knitr` in `DESCRIPTION`.
- Exact wording of the thrown error message (state + last N log lines —
  N to be decided during implementation, not a design-level concern).
- Whether `viya_submit_quarto()`'s exported signature should accept
  `output` as a single value or `several.ok = TRUE` like `viya_submit()`
  — should match `viya_submit()`'s existing `match.arg(..., several.ok = TRUE)`
  behavior for consistency, applied during implementation.
