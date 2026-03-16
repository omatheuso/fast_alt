# FastAlt

Automatically generate `alt` text for images in compiled HTML output using local AI inference (BLIP). Scan HTML files for missing or empty `alt` attributes, run vision inference on each image, and either report findings or patch the files in-place.

Primary use case: **CI/CD pipeline lint gate** — fail a build when images lack accessibility descriptions, and optionally auto-fix them before deployment.

A Phoenix LiveView playground is included for interactive, browser-based testing.

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| Elixir ≥ 1.15 | Runtime | [elixir-lang.org](https://elixir-lang.org/install.html) |
| libvips | Image decoding (WebP, AVIF, HEIC, TIFF, …) | `brew install vips` / `apt install libvips-dev` |
| HuggingFace model weights | BLIP captioning model (~1 GB, downloaded once) | automatic on first run |

---

## Setup

```bash
# 1. Install system dependency
brew install vips          # macOS
apt install libvips-dev    # Ubuntu / Debian

# 2. Install Elixir deps and download the BLIP model weights
mix setup
```

The model is downloaded once and cached at `~/.cache/bumblebee/` (or `$BUMBLEBEE_CACHE_DIR` if set). Subsequent runs load from cache.

---

## CLI usage

### Scan a directory (report only)

```bash
mix fast_alt.scan ./dist
```

Walks `./dist` recursively, finds every `<img>` tag missing or with an empty `alt` attribute, runs BLIP inference on each local image, and prints a report.

```
FastAlt scan: dist/
  4 image(s) missing alt

  [FOUND]   dist/index.html  →  hero.jpg         →  "a dashboard interface screenshot"
  [FOUND]   dist/about.html  →  team.png         →  "three people standing in an office"
  [SKIP]    dist/index.html  →  https://cdn.…    →  external URL
  [SKIP]    dist/index.html  →  data:image/…     →  data URI
```

**Exit codes:**
- `0` — all images already had non-empty `alt` attributes (CI passes)
- `1` — one or more images were missing `alt` (CI fails)

### Patch HTML files in-place

```bash
mix fast_alt.scan --patch ./dist
```

Same as above but rewrites each HTML file with the generated `alt` attributes injected. Lines change from `[FOUND]` to `[PATCHED]`.

> **Note:** LazyHTML normalizes HTML on round-trip (quote style, self-closing tags, whitespace). Use `--patch` on compiled/generated output only — not on hand-crafted templates you maintain by hand.

### JSON output

```bash
mix fast_alt.scan --format json ./dist
mix fast_alt.scan --format json --out report.json ./dist
```

```json
{
  "scan_root": "dist/",
  "summary": {
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

### All flags

| Flag | Short | Default | Description |
|---|---|---|---|
| `--patch` | `-p` | false | Rewrite HTML files in-place with generated `alt` text |
| `--format` | `-f` | `text` | Output format: `text` or `json` |
| `--out` | | stdout | Write report to a file path instead of stdout |

---

## CI/CD integration

### GitHub Actions

Add this step to any workflow that builds and deploys your frontend:

```yaml
- name: Check image alt text
  run: mix fast_alt.scan ./dist
```

To auto-patch and commit missing alt text before deploying:

```yaml
- name: Generate and inject missing alt text
  run: |
    mix fast_alt.scan --patch ./dist
    git config user.name  "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add dist/
    git diff --cached --quiet || git commit -m "chore: inject generated alt text"
```

### Model caching (important for performance)

Without caching the BLIP model is re-downloaded (~1 GB) on every CI run. Add a cache step before the scan:

```yaml
- name: Cache Bumblebee model weights
  uses: actions/cache@v4
  with:
    path: ~/.cache/bumblebee
    key: bumblebee-blip-${{ hashFiles('mix.lock') }}
    restore-keys: bumblebee-blip-

- name: Check image alt text
  run: mix fast_alt.scan ./dist
```

The cache key is tied to `mix.lock` so it is automatically invalidated if you upgrade Bumblebee or swap models.

**Custom cache path** — if your runner does not have a writable home directory:

```yaml
env:
  BUMBLEBEE_CACHE_DIR: .bumblebee-cache

- name: Cache Bumblebee model weights
  uses: actions/cache@v4
  with:
    path: .bumblebee-cache
    key: bumblebee-blip-${{ hashFiles('mix.lock') }}

- name: Check image alt text
  run: mix fast_alt.scan ./dist
```

### GitLab CI

```yaml
check-alt-text:
  cache:
    key: bumblebee-blip-${CI_COMMIT_REF_SLUG}
    paths:
      - .bumblebee-cache/
  variables:
    BUMBLEBEE_CACHE_DIR: .bumblebee-cache
  script:
    - mix fast_alt.scan ./dist
```

### Skip model load in unrelated CI jobs

If you run `mix test` or other tasks in CI that boot the full application, set this flag to skip loading the BLIP model at startup:

```elixir
# config/test.exs
config :fast_alt, start_serving: false
```

---

## What gets skipped

The scanner skips the following `src` values without running inference:

| Pattern | Reason |
|---|---|
| `data:…` | Inline base64 — no file on disk |
| `http://…` / `https://…` | External URL — not readable locally |
| `//…` | Protocol-relative external URL |
| Relative path where file does not exist | Missing asset |

Images that already have a non-empty `alt` attribute are not included in results at all.

---

## Web playground

Start the Phoenix server to interactively test the inference pipeline in a browser:

```bash
mix phx.server
# visit http://localhost:4000
```

Upload any image (JPG, PNG, WebP, GIF, BMP, TIFF — up to 20 MB) and get the AI-generated caption live.

---

## Elixir library API

You can call the scanner programmatically from your own Mix tasks or scripts:

```elixir
# Report only
{:ok, results} = FastAlt.Scanner.scan("./dist")

# Patch in-place
{:ok, results} = FastAlt.Scanner.scan("./dist", patch: true)

# Check results
missing = Enum.reject(results, & &1.skipped)
IO.puts("#{length(missing)} images need alt text")
```

Individual modules are also usable standalone:

```elixir
# Find all HTML files under a directory
FastAlt.FileScanner.find_html_files("./dist")
#=> ["/abs/dist/index.html", "/abs/dist/about.html"]

# Extract img tags from an HTML string
FastAlt.HTMLScanner.scan_html(File.read!("index.html"))
#=> [%{src: "hero.jpg", alt: nil}, %{src: "logo.png", alt: "our logo"}]

# Resolve a src value to an absolute disk path
FastAlt.ImageResolver.resolve("hero.jpg", "/abs/dist/index.html")
#=> {:ok, "/abs/dist/hero.jpg"}

FastAlt.ImageResolver.resolve("https://cdn.example.com/img.jpg", "/abs/dist/index.html")
#=> {:skip, "external URL"}

# Patch a file directly
FastAlt.AltPatcher.patch_file("/abs/dist/index.html", [{"hero.jpg", "a hero image"}])
#=> :ok
```

---

## Known limitations

- **BLIP output quality:** BLIP is an image captioning model, not a semantic alt-text generator. Captions are descriptive but may not be ideal accessibility descriptions. Human review is recommended before committing patched output.
- **HTML normalization on patch:** `--patch` normalizes HTML structure on round-trip (whitespace, quote style, self-closing tags). Safe for machine-generated build output; avoid on hand-crafted templates.
- **Model load time:** The BLIP model takes several seconds to load on first run per CI job. Mitigate with the model cache step above.
- **Local images only:** Remote images and data URIs are always skipped.
