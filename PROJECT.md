# FastAlt — Project Summary

## Purpose

FastAlt is an Elixir library and Mix task for automatically generating `alt` text for images in compiled frontend output. It scans HTML files for `<img>` tags missing or empty `alt` attributes, runs local AI vision inference on each image, and either reports the findings or patches the HTML files in-place.

The primary use case is CI/CD pipelines: fail a build when images lack accessibility descriptions, and optionally auto-fix them before deployment.

A Phoenix LiveView playground is included for interactive, browser-based testing.

## Tech Stack

| Layer | Technology |
|---|---|
| Web Framework | Phoenix 1.8 + LiveView 1.1 (playground only) |
| HTTP Adapter | Bandit 1.5 |
| ML Inference | Bumblebee 0.5 + Nx 0.7 + EXLA 0.7 (XLA backend) |
| Vision Model | `Salesforce/blip-image-captioning-base` (HuggingFace) |
| Image Decoding | `Image` 0.63 (libvips) → `StbImage` 0.6 (Bumblebee compat) |
| HTML Parsing | LazyHTML (Lexbor NIF, same as Phoenix LiveView) |
| CSS | Tailwind CSS v4 + daisyUI |
| JS Bundler | esbuild |
| JSON | Jason |

**No database** — stateless. Images are read from disk; any temp files are cleaned up after processing.

## System Dependencies

| Dependency | Purpose | Install |
|---|---|---|
| libvips | Image decoding (WebP, AVIF, HEIC, TIFF, …) | `brew install vips` / `apt install libvips-dev` |
| HuggingFace Hub | BLIP model weights (downloaded once at first boot) | (automatic) |

## Architecture Overview

### Library / CI path

```
mix fast_alt.scan ./dist
        │
        ▼
FastAlt.FileScanner
  walks dist/ → list of .html files
        │
        ▼
FastAlt.HTMLScanner          (per HTML file)
  LazyHTML → img tags missing alt
        │
        ▼
FastAlt.ImageResolver
  src → absolute disk path
  skips: external URLs, data URIs, missing files
        │
        ▼
FastAlt.CaptionServing.run/2  (per image)
  Image.open → PNG binary → StbImage → Nx.Serving
  → BLIP inference → caption string
        │
        ▼
FastAlt.AltPatcher            (if --patch)
  LazyHTML round-trip → inject alt attrs → write file
        │
        ▼
FastAlt.Scanner
  collects results → JSON or text report → exit 0/1
```

### Web playground path

```
User uploads image (JPG, PNG, WebP, GIF, BMP, TIFF)
        │
        ▼
FastAltWeb.ConverterLive
  consumes upload → writes to tmp
  spawns Task via TaskSupervisor
        │
        ▼
FastAlt.CaptionServing.run/1
  Image.open → PNG binary → StbImage
  Nx.Serving → BLIP → caption string
        │
        ▼
  {:inference_complete, caption} sent to LiveView
  UI displays result
```

## Key Modules

### Library core

**`FastAlt.Scanner`** — top-level orchestrator
- Wires `FileScanner`, `HTMLScanner`, `ImageResolver`, `CaptionServing`, `AltPatcher`
- Accepts `patch:`, `format:`, and `serving:` options
- Uses `Task.async_stream` over HTML files for concurrent I/O with controlled back-pressure

**`FastAlt.FileScanner`**
- Recursively walks a directory and returns all `.html` / `.htm` file paths
- No dependencies beyond the standard library

**`FastAlt.HTMLScanner`**
- Parses an HTML binary with LazyHTML
- Extracts all `<img>` entries; `alt: nil` = attribute absent, `alt: ""` = present but blank

**`FastAlt.ImageResolver`**
- Resolves a `src` value relative to its containing HTML file
- Returns `{:ok, absolute_path}` or `{:skip, reason}`
- Skips: `data:` URIs, `http://` / `https://` / `//` URLs, files that don't exist on disk

**`FastAlt.CaptionServing`**
- Loads `Salesforce/blip-image-captioning-base` from HuggingFace at startup
- Decodes images via `Image` (libvips) → in-memory PNG → `StbImage` for Bumblebee
- Supports all formats libvips can open: JPEG, PNG, WebP, AVIF, HEIC, TIFF, GIF, BMP, and more
- `run/1` uses the supervision-tree serving; `run/2` accepts a custom serving name for CI use

**`FastAlt.AltPatcher`**
- Reads an HTML file, uses LazyHTML tree manipulation to inject `alt` attributes
- Writes the patched file back to disk
- Known trade-off: LazyHTML normalizes HTML on round-trip (whitespace, self-closing tags)

### Mix task

**`Mix.Tasks.FastAlt.Scan`**
- Entrypoint: `mix fast_alt.scan [OPTIONS] <directory>`
- Starts a transient `Nx.Serving` supervisor (no Phoenix app required)
- Reports findings to stdout; exits `1` if any images were missing alt

```
Options:
  --patch   / -p   Rewrite HTML files in-place with generated alt text
  --format  / -f   text (default) or json
  --out            Write report to a file instead of stdout
```

### Web layer

**`FastAltWeb.ConverterLive`** — the only LiveView (playground)
- Accepts: JPG, JPEG, PNG, BMP, GIF, WebP, TIFF (max 20 MB)
- State machine: `:idle` → `:processing` → `:done`
- Spawns async Task; displays caption on completion

**`FastAltWeb.Router`**
```
GET /               → ConverterLive
GET /dev/dashboard  → Phoenix LiveDashboard (dev only)
```

## Supervision Tree

```
FastAlt.Application
├── Telemetry
├── DNS Cluster
├── PubSub
├── TaskSupervisor         (async image processing in the web playground)
├── Nx.Serving             (BLIP model — skipped when start_serving: false)
└── Endpoint               (web playground)
```

The `Nx.Serving` child is controlled by a config flag:
```elixir
config :fast_alt, start_serving: false  # set this in CI to skip model load at boot
```

When `false`, the Mix task starts its own short-lived serving and tears it down after the scan.

## LiveView State (playground)

| Assign | Type | Description |
|---|---|---|
| `state` | atom | `:idle` / `:processing` / `:done` |
| `caption` | string | Generated alt text |
| `error` | string / nil | Error message |
| `uploads` | LiveView upload | Image upload config |

## Mix Task Output

**Text format:**
```
FastAlt scan: dist/
  3 HTML files · 7 img tags · 4 missing alt

  [PATCHED]  dist/index.html  →  hero.jpg    →  "a dashboard interface screenshot"
  [PATCHED]  dist/about.html  →  team.png    →  "three people standing in an office"
  [SKIP]     dist/index.html  →  https://…   →  external URL
  [OK]       dist/index.html  →  icon.svg    →  already has alt
```

**JSON format:**
```json
{
  "scan_root": "dist/",
  "summary": { "html_files": 3, "img_tags": 7, "missing_alt": 4, "patched": 2, "skipped": 1 },
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

**Exit codes:** `0` = all images already had alt text · `1` = missing alt found (CI lint gate)

## Configuration

**Nx backend:** EXLA (configured in `config/config.exs`)

**Runtime env vars (production):**
- `SECRET_KEY_BASE` — required
- `PORT` — default 4000
- `PHX_SERVER` — set to enable server mode

**Assets:**
- Tailwind v4 — uses `@import "tailwindcss"` in `app.css`, no `tailwind.config.js`
- daisyUI themes: `light` and `dark`

## Setup

```bash
# System deps (required for image decoding)
brew install vips          # macOS
apt install libvips-dev    # Ubuntu/Debian

mix setup                  # install Elixir deps + download BLIP model weights
mix phx.server             # start the web playground at localhost:4000

# CI/CD usage
mix fast_alt.scan ./dist                    # report only
mix fast_alt.scan --patch ./dist            # report + patch HTML files
mix fast_alt.scan --format json ./dist      # JSON output
```

## Known Limitations / Trade-offs

- **BLIP output quality:** BLIP is an image captioning model, not a semantic alt-text generator. Captions are descriptive but may not be ideal accessibility descriptions. Human review is recommended before committing patched output.
- **HTML normalization on patch:** LazyHTML normalizes HTML on round-trip (whitespace, self-closing tags). Avoid `--patch` on hand-crafted templates you want to keep formatted exactly.
- **Model load time:** The BLIP model takes seconds to load on first run. In CI, this cost is paid once per job. Pre-warming is not supported in v1.
- **No authentication or rate limiting** in the web playground.
