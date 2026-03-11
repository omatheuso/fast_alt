# PDF to Markdown Converter — Project Summary

## Purpose

A Phoenix LiveView web application that converts PDF documents to Markdown using local AI vision inference. Users upload a PDF, the app renders each page to an image, runs vision-language inference on each image, and streams the Markdown output back to the UI in real time.

## Tech Stack

| Layer | Technology |
|---|---|
| Web Framework | Phoenix 1.8.3 + LiveView 1.1.0 |
| HTTP Adapter | Bandit 1.5 |
| ML Inference | Bumblebee 0.5 + Nx 0.7 + EXLA 0.7 (XLA backend) |
| Vision Model | `Salesforce/blip-image-captioning-base` (HuggingFace) |
| Image Loading | StbImage 0.6 |
| PDF Rendering | `pdftoppm` CLI (Poppler system dependency) |
| CSS | Tailwind CSS v4 + daisyUI (light/dark themes) |
| JS Bundler | esbuild |
| JSON | Jason |

**No database** — stateless compute app. Files are written to `System.tmp_dir()` and cleaned up after processing.

## Architecture Overview

```
User uploads PDF
       │
       ▼
ConverterLive (LiveView)
  spawns Task via TaskSupervisor
       │
       ▼
PdfRenderer.render_pages/2
  calls pdftoppm → JPEG images in /tmp
       │
       ▼
MarkdownServing.run/1  (per page)
  Nx.Serving → Bumblebee BLIP model → text
       │
       ▼
  Messages sent back to LiveView
  (:page_complete, :processing_done, :processing_failed)
       │
       ▼
UI updates in real time (streaming markdown output)
```

## Key Modules

### Domain Logic

**`PdfToMd.PdfRenderer`**
- Calls `pdftoppm` to render PDF pages as JPEGs into a temp dir
- Hard limit: `@max_pages = 1` (only first page processed)
- Returns `{page_paths, cleanup_fn}` — cleanup always called even on error

**`PdfToMd.MarkdownServing`**
- Loads `Salesforce/blip-image-captioning-base` from HuggingFace at app startup
- Registers an `Nx.Serving` (batch size 1) under the app supervisor
- Exposes `run(image_path)` → returns Markdown string for that page image

### Web Layer

**`PdfToMdWeb.ConverterLive`** — the only LiveView
- Manages upload (max 50 MB, PDF only, 1 file at a time)
- State machine: `:idle` → `:processing` → `:done`
- Spawns async Task for processing; receives progress messages
- Accumulates markdown output page-by-page with real-time display
- Provides copy-to-clipboard and reset functionality

**`PdfToMdWeb.Router`**
```
GET /          → ConverterLive  (single route)
GET /dev/dashboard  → Phoenix LiveDashboard (dev only)
```

**`PdfToMd.Application`**
Supervision tree:
```
Application
├── Telemetry
├── DNS Cluster
├── PubSub
├── TaskSupervisor  (for async PDF processing)
├── Nx.Serving      (Bumblebee BLIP model)
└── Endpoint
```

## LiveView State

| Assign | Type | Description |
|---|---|---|
| `state` | atom | `:idle` / `:processing` / `:done` |
| `markdown_output` | string | Accumulated Markdown so far |
| `error` | string / nil | Error message to display |
| `total_pages` | integer | Total pages to process |
| `current_page` | integer | Pages processed so far |
| `uploads` | LiveView upload | PDF file upload config |

## Processing Flow (detail)

1. User submits form → `"upload"` event fires
2. LiveView consumes upload, writes PDF to tmp dir
3. `Task.Supervisor.start_child/2` spawns `process_pdf/2`
4. Task sends `{:processing_started, total_pages}` to LiveView pid
5. For each page:
   - `PdfRenderer` renders page → JPEG
   - `MarkdownServing.run/1` calls Bumblebee inference → text
   - Task sends `{:page_complete, page_num, markdown_chunk}` to LiveView
6. After all pages: Task sends `{:processing_done}` or `{:processing_failed, reason}`
7. Temp dirs cleaned up in `after` block regardless of outcome

## Configuration

**Nx backend:** EXLA (configured in `config/config.exs`)

**Runtime env vars (production):**
- `SECRET_KEY_BASE` — required
- `PORT` — default 4000
- `PHX_SERVER` — set to enable server mode

**Assets:**
- Tailwind v4 — no `tailwind.config.js`, uses `@import "tailwindcss"` in `app.css`
- daisyUI themes: `light` and `dark`
- Custom Elixir/Phoenix-inspired color palette

## External Dependencies

| Dependency | Purpose | Notes |
|---|---|---|
| HuggingFace Hub | Model weights download | Only at startup / first run |
| `pdftoppm` (Poppler) | PDF → image conversion | System dep, must be installed |

Install system deps:
```bash
brew install poppler   # macOS
apt install poppler-utils  # Ubuntu/Debian
```

## Setup

```bash
mix setup         # installs deps, downloads model weights
mix phx.server    # starts server at localhost:4000
```

## Known Limitations

- Only processes the **first page** of a PDF (`@max_pages = 1`)
- BLIP is an image captioning model, not an OCR/transcription model — output quality for text-heavy PDFs may be poor (recent commit: "LLM doing a stupid job")
- No persistence — results are lost on page refresh
- No authentication or rate limiting
