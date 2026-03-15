# FastAlt — Library Pivot Implementation Plan

## Status: pending implementation

---

## 1. Module Structure

### Modules to rename / restructure

**`FastAlt.MarkdownServing` → `FastAlt.CaptionServing`**

Rename only — logic stays identical. The module name and `@moduledoc` are updated to reflect the shift from "markdown conversion" to "image captioning for alt text". Add a two-arity `run/2` that accepts a custom serving name atom (for CI/CD use where the serving is not registered under the module name).

### New modules to create

**`FastAlt.HTMLScanner`**
Pure data transformation. Given an HTML binary, returns every `<img>` entry with its `src` and `alt` values. `alt: nil` = attribute absent, `alt: ""` = present but blank. Uses LazyHTML internally.

**`FastAlt.FileScanner`**
Recursively walks a directory and collects all `.html` / `.htm` file paths. Returns a sorted list of absolute paths. No dependencies beyond the standard library.

**`FastAlt.ImageResolver`**
Given an `img src` value and the absolute path of the HTML file containing it, resolves the image to a disk path. Returns `{:ok, absolute_path}` or `{:skip, reason}`. Skips: `data:` URIs, `http://` / `https://` / `//` URLs, and files that don't exist on disk.

**`FastAlt.AltPatcher`**
Given an HTML file path and a list of `{src, generated_alt}` pairs, rewrites the file in-place using LazyHTML tree manipulation to inject or replace `alt` attributes. Only called when `--patch` is passed.

**`FastAlt.Scanner`**
Top-level orchestrator. Wires together `FileScanner`, `HTMLScanner`, `ImageResolver`, `CaptionServing`, and `AltPatcher`. All functions return tagged tuples. Uses `Task.async_stream` over HTML files for concurrent I/O; inference is serialized through the single `Nx.Serving` batch queue.

**`Mix.Tasks.FastAlt.Scan`** (`lib/mix/tasks/fast_alt.scan.ex`)
CLI entry point for CI/CD pipelines. Parses argv, starts a transient `Nx.Serving` supervisor, calls `FastAlt.Scanner.scan/2`, formats and prints the report, exits with `0` or `1`.

---

## 2. Public API

### `FastAlt.Scanner`

```elixir
@type result :: %{
  html_file: String.t(),
  img_src: String.t(),
  img_path: String.t() | nil,
  generated_alt: String.t() | nil,
  skipped: boolean(),
  skip_reason: String.t() | nil
}

@type scan_opts :: [
  patch: boolean(),
  format: :json | :text,
  serving: atom() | nil
]

@spec scan(dir :: String.t(), opts :: scan_opts()) ::
  {:ok, [result()]} | {:error, term()}
```

### `FastAlt.HTMLScanner`

```elixir
@type img_entry :: %{src: String.t(), alt: String.t() | nil}

@spec scan_html(html_binary :: String.t()) :: [img_entry()]
```

### `FastAlt.FileScanner`

```elixir
@spec find_html_files(root :: String.t()) :: [String.t()]
```

### `FastAlt.ImageResolver`

```elixir
@spec resolve(src :: String.t(), html_file_path :: String.t()) ::
  {:ok, String.t()} | {:skip, String.t()}
```

### `FastAlt.CaptionServing`

```elixir
@spec serving() :: Nx.Serving.t()
@spec run(image_path :: String.t()) :: String.t()
@spec run(image_path :: String.t(), serving_name :: atom()) :: String.t()
```

### `FastAlt.AltPatcher`

```elixir
@spec patch_file(
  html_path :: String.t(),
  patches :: [{src :: String.t(), alt :: String.t()}]
) :: :ok | {:error, term()}
```

---

## 3. Mix Task Design

### Invocation

```
mix fast_alt.scan [OPTIONS] <directory>
```

### Flags

| Flag | Default | Description |
|---|---|---|
| `--patch` / `-p` | false | Rewrite HTML files in-place with generated `alt` attributes |
| `--format` / `-f` | `text` | Output format: `text` or `json` |
| `--out` | stdout | Write report to a file path instead of stdout |

### Text output

```
FastAlt scan: dist/
  3 HTML files · 7 img tags · 4 missing alt

  [PATCHED]  dist/index.html  →  hero.jpg    →  "a dashboard interface screenshot"
  [PATCHED]  dist/about.html  →  team.png    →  "three people standing in an office"
  [SKIP]     dist/index.html  →  https://…   →  external URL
  [OK]       dist/index.html  →  icon.svg    →  already has alt
```

### JSON output

```json
{
  "scan_root": "dist/",
  "summary": {
    "html_files": 3,
    "img_tags": 7,
    "missing_alt": 4,
    "patched": 2,
    "skipped": 1
  },
  "results": [
    {
      "html_file": "dist/index.html",
      "img_src": "hero.jpg",
      "img_path": "/abs/dist/hero.jpg",
      "generated_alt": "a dashboard interface screenshot",
      "patched": true,
      "skipped": false,
      "skip_reason": null
    }
  ]
}
```

### Exit codes

- `0` — all images already had non-empty alt attributes
- `1` — one or more images were missing alt (whether or not patched) — fails CI pipeline as a lint gate

---

## 4. Supervision Tree Changes

### Problem

`FastAlt.Application` unconditionally starts the `Nx.Serving` (BLIP model load) at every boot — including `mix test` and when the Mix task calls `app.config`. This is expensive and wrong for CI.

### Fix

Wrap the `Nx.Serving` child in `application.ex` behind a config flag:

```elixir
# Conceptual change — not exact code:
serving_children =
  if Application.get_env(:fast_alt, :start_serving, true) do
    [{Nx.Serving,
      serving: FastAlt.CaptionServing.serving(),
      name: FastAlt.CaptionServing,
      batch_size: 1}]
  else
    []
  end
```

Default is `true` — web server is unaffected.

### Mix task lifecycle

The task calls `Mix.Task.run("app.config")`, not `app.start`, so the supervision tree never boots. The task starts its own short-lived supervisor:

```elixir
# Conceptual task logic:
{:ok, sup} = Supervisor.start_link([
  {Nx.Serving,
   serving: FastAlt.CaptionServing.serving(),
   name: FastAlt.CIPipeline.Serving,
   batch_size: 1}
], strategy: :one_for_one)

FastAlt.Scanner.scan(dir, serving: FastAlt.CIPipeline.Serving, ...)

Supervisor.stop(sup)
```

---

## 5. HTML Parsing Approach

**Decision: promote `lazy_html` from `only: :test` to a full runtime dependency.**

Change in `mix.exs`: remove `only: :test` from `{:lazy_html, ">= 0.1.0"}`. No new package. It is already in `mix.lock`.

**Justification:**
- Authored by Dashbit — same team as Phoenix/LiveView; actively maintained
- NIF-backed Lexbor engine handles malformed HTML correctly (common in generated build output)
- CSS selector model covers both cases in one query: `"img:not([alt]), img[alt='']"`
- Enables `AltPatcher` via `to_tree` / `from_tree` / `to_html` round-trip

**Known trade-off:** `LazyHTML.to_html/1` normalizes HTML (whitespace, self-closing tags). Acceptable for generated build output; documented as a known limitation of `--patch`.

---

## 6. File / Directory Layout

```
lib/
  fast_alt/
    application.ex              ← MODIFY: conditionalize Nx.Serving child
    caption_serving.ex          ← RENAME from markdown_serving.ex; add run/2
    scanner.ex                  ← NEW
    html_scanner.ex             ← NEW
    file_scanner.ex             ← NEW
    image_resolver.ex           ← NEW
    alt_patcher.ex              ← NEW
  fast_alt_web/
    live/
      converter_live.ex         ← MODIFY: update module ref to CaptionServing

lib/mix/tasks/
  fast_alt.scan.ex              ← NEW

test/
  fast_alt/
    html_scanner_test.exs       ← NEW
    file_scanner_test.exs       ← NEW
    image_resolver_test.exs     ← NEW
    alt_patcher_test.exs        ← NEW
    scanner_test.exs            ← NEW (integration, mocked serving)
```

---

## 7. Step-by-Step Implementation Order

Each step leaves the system in a working, compilable state.

### Step 1 — Rename the serving module
- Rename `lib/fast_alt/markdown_serving.ex` → `lib/fast_alt/caption_serving.ex`
- Change module name `FastAlt.MarkdownServing` → `FastAlt.CaptionServing`
- Update `@moduledoc` to describe alt-text captioning purpose
- Add two-arity `run/2` that accepts a custom serving name atom
- **Verify:** `mix compile` passes

### Step 2 — Update all references to the old module name
- `lib/fast_alt/application.ex` — update `Nx.Serving` child spec name
- `lib/fast_alt_web/live/converter_live.ex` — update `run/1` call site
- **Verify:** `mix compile --warnings-as-errors` passes; `mix phx.server` starts cleanly

### Step 3 — Promote LazyHTML to a runtime dependency
- In `mix.exs`, remove `only: :test` from `lazy_html`
- **Verify:** `mix deps` shows `lazy_html` as a normal dep

### Step 4 — Conditionalize the Nx.Serving child
- Wrap `{Nx.Serving, ...}` in `application.ex` with `Application.get_env(:fast_alt, :start_serving, true)`
- **Verify:** `mix phx.server` still loads the model; setting the flag to `false` skips it

### Step 5 — Implement `FastAlt.FileScanner`
- Create `lib/fast_alt/file_scanner.ex`
- `find_html_files/1` using recursive `File.ls!/1`; filter by `.html` / `.htm` extension
- Write `test/fast_alt/file_scanner_test.exs` using `System.tmp_dir!()` fixtures
- **Verify:** tests pass

### Step 6 — Implement `FastAlt.HTMLScanner`
- Create `lib/fast_alt/html_scanner.ex`
- Parse with `LazyHTML.from_document/1`, query `"img"`, extract `src` and `alt` per node
- Write `test/fast_alt/html_scanner_test.exs` covering: no img, absent alt, empty alt, present alt, multiple imgs, malformed HTML
- **Verify:** tests pass

### Step 7 — Implement `FastAlt.ImageResolver`
- Create `lib/fast_alt/image_resolver.ex`
- Skip `data:`, `http://`, `https://`, `//` prefixes
- Resolve relative paths against `Path.dirname/1` of the HTML file
- Check `File.exists?/1`; return `{:skip, "file not found"}` if missing
- Write `test/fast_alt/image_resolver_test.exs`
- **Verify:** tests pass

### Step 8 — Implement `FastAlt.AltPatcher`
- Create `lib/fast_alt/alt_patcher.ex`
- Read file → `LazyHTML.from_document/1` → `to_tree/1` → walk tree → inject `alt` → `from_tree/1` → `to_html/1` → `File.write!/2`
- Write `test/fast_alt/alt_patcher_test.exs` using tmp file fixtures
- **Verify:** tests pass

### Step 9 — Implement `FastAlt.Scanner`
- Create `lib/fast_alt/scanner.ex`
- `scan/2`: validate dir → `FileScanner` → per file: read + `HTMLScanner` + filter missing alt → `ImageResolver` → `CaptionServing.run/2` → collect results → optionally `AltPatcher`
- Use `Task.async_stream/3` with `timeout: :infinity` over HTML files
- Write `test/fast_alt/scanner_test.exs` with a stub `Nx.Serving` returning fixed strings
- **Verify:** tests pass

### Step 10 — Implement `Mix.Tasks.FastAlt.Scan`
- Create `lib/mix/tasks/fast_alt.scan.ex`
- `OptionParser.parse!/2` for flags → `Mix.Task.run("app.config")` → start transient supervisor with `Nx.Serving` → `Scanner.scan/2` → format output → `Supervisor.stop/1` → `System.halt/1`
- **Verify:** `mix fast_alt.scan --format json ./priv` runs without error

### Step 11 — Run precommit
- `mix precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`)
- Fix any issues that surface

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| LazyHTML for HTML parsing and patching | Already present, Dashbit-maintained, handles malformed HTML, CSS selector API is expressive |
| `Image` (libvips) as the image decoder | Supports WebP, AVIF, HEIC, TIFF — far beyond what StbImage alone handles |
| Keep StbImage | Bumblebee's featurizer requires a `StbImage` struct; `Image` → in-memory PNG → `StbImage.read_binary!/2` bridges the gap |
| `Task.async_stream` concurrency | Parallelizes file I/O and HTML parsing; inference is naturally serialized by the `Nx.Serving` batch queue — no OOM risk |
| Transient serving in Mix task | Keeps serving lifecycle entirely inside the task; no `app.start` needed; model loaded fresh per CI run |
| Config flag for `start_serving` | Zero-cost for existing web use; allows CI to skip the expensive model load entirely when `--serving` points to an external process |
| Exit code `1` on any missing alt | Follows Unix convention for lint gates; CI fails the pipeline as a warning by default |
