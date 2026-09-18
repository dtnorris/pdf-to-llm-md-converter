# pdf-to-llm-md-converter

A Ruby-first pilot for converting PDF books into page-addressable Markdown suitable for downstream editorial and LLM review.

Ruby owns orchestration, page splitting, canonical page markers, assembly, and validation. The normal converter now routes each isolated page between Docling and Apple Vision using deterministic source-text signals, while keeping the adapter boundary explicit for debugging and reproducibility.

## Requirements

- macOS with Homebrew (commands below assume Apple Silicon; Intel paths may differ)
- Xcode Command Line Tools / `xcrun` for Apple Vision OCR in automatic scanned-page mode
- Ruby 3.2+
- Bundler 4.0.17 (the version recorded in `Gemfile.lock`)
- Python 3.10+
- Poppler utilities: `pdfinfo`, `pdfseparate`, `pdftotext`, and `pdftoppm`
- `qpdf`
- `tesseract` (visual printed-page fallback)
- Python environment with the `docling` CLI installed

Docling's official CLI supports Markdown output and image placeholders. The command is configurable in `config/conversion.yml` rather than embedded in application code.

## Fresh-machine setup (macOS)

These steps are intended to work from a clean macOS development environment and avoid relying on Apple's system Ruby.

### 1. Install Homebrew dependencies

```bash
brew install ruby python poppler qpdf tesseract
```

On Apple Silicon, make sure Homebrew Ruby is ahead of Apple's system Ruby:

```bash
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
source ~/.zshrc
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Verify that Ruby is not `/usr/bin/ruby`:

```bash
which ruby
ruby --version
```

Ruby 3.2 or newer is required.

### 2. Install the Bundler version required by the lockfile

`Gemfile.lock` is currently generated with Bundler 4.0.17:

```bash
gem install bundler -v 4.0.17
bundle --version
```

Do not install Bundler into Apple's system Ruby with `sudo gem install`.

### 3. Run the repository-owned setup

```bash
bin/setup
source .venv/bin/activate
```

`bin/setup` is idempotent. It installs the bundled Ruby dependencies, creates or
reuses the repository-local `.venv`, and installs Docling into that virtual
environment. It does not install Homebrew/system packages or global Python
packages. Set `PDF_TO_LLM_PYTHON` to override the `python3` used to create the
virtual environment.

Docling downloads model assets from Hugging Face on first use. If Hugging Face's Xet downloader fails with an error such as:

```text
File reconstruction error: Internal Writer Error: Byte range not sequential
```

disable Xet before running the converter:

```bash
export HF_HUB_DISABLE_XET=1
```

If this is required on your machine, make it persistent:

```bash
echo 'export HF_HUB_DISABLE_XET=1' >> ~/.zshrc
```

### 4. Verify all runtime dependencies

Run these before the first conversion:

```bash
ruby --version
bundle --version
python --version
docling --help
pdfinfo -v
pdfseparate -v
pdftotext -v
pdftoppm -v
qpdf --version
tesseract --version
```

If any command is missing, fix it before running `bin/convert`.

## Normal startup

Each time you open a new shell:

```bash
cd /path/to/pdf-to-llm-md-converter
source .venv/bin/activate
```

If needed on your machine:

```bash
export HF_HUB_DISABLE_XET=1
```

## Convert a PDF

General form:

```bash
bin/convert /path/to/input.pdf \
  --title "Document Title" \
  --output-dir /path/to/output
```

Example:

```bash
bin/convert fixtures/labyrinth_sample.pdf \
  --title "Labyrinth Adventures — Pilot Sample" \
  --output-dir build
```

Convert a limited range:

```bash
bin/convert fixtures/labyrinth_sample.pdf --from 3 --to 8
```

### Automatic backend selection

`bin/convert` defaults to `--backend auto`. For each qpdf-isolated page, auto mode
uses `pdftotext` plus PDF-font presence to decide whether the page has enough
native text to remain on Docling. Pages that are effectively image-only/scanned
use Apple Vision when macOS, `xcrun`, and `pdftoppm` are available.

Force a backend when reproducing or debugging a conversion:

```bash
bin/convert input.pdf --backend docling
bin/convert input.pdf --backend apple-vision
bin/convert input.pdf --backend auto
```

If auto mode classifies a page as scanned and Apple Vision is unavailable, the
conversion fails closed instead of silently falling back to Docling OCR. A forced
`--backend apple-vision` likewise fails deterministically when its platform
dependencies are unavailable.

Vision remains deliberately conservative around dense tables. Repeated multi-cell
row geometry is treated as table-like. Auto mode tries Docling as a fallback only
when Docling emits actual table structure with adequate text coverage; otherwise
the page is marked extraction-quality invalid and requires review. No
page-number-specific routing rules are used.

### Extraction-quality validation

Structural validation (page markers, duplicates/missing pages, gross blankness,
and flagged characters) remains separate from the extraction-quality gate. The
quality gate compares extracted text with independent evidence available for the
page, such as native PDF text or Vision-recognized observations, and rejects
severe coverage collapse. Sparse pages are not rejected solely because they have
few words.

A quality failure prints the PDF page number, selected backend, and the triggered
reason, and `bin/convert` exits with status 2 even if structural validation passes.
The Markdown is left in the requested output directory for diagnosis, but the CLI
does not report the conversion as clean.

The first Docling conversion may be significantly slower because model files are downloaded and initialized. Subsequent runs should reuse the local model cache.

### Repair printed-page markers without reconversion

If the Markdown content and `<!-- PDF Page N -->` markers are already good but automatic printed-page detection was wrong, relabel only the pagination metadata:

```bash
bin/relabel-printed-pages existing.md \
  --offset -1 \
  --expect-pages 259 \
  --output repaired.md
```

`relabel-printed-pages` never invokes Docling or reads the PDF. It requires an explicit offset, refuses in-place mutation and output overwrite, requires unique contiguous PDF markers, removes existing `Printed Page` / `PDF Page Label` annotations immediately following PDF markers, and writes the replacement printed-page annotations to a new file. Pages whose offset result is zero or negative receive no printed-page marker. It verifies that non-pagination Markdown content is byte-for-byte identical before publishing the output.

## Troubleshooting

### `Could not find 'bundler' (4.0.17)`

If the traceback points at `/System/Library/Frameworks/Ruby.framework/...`, you are using Apple's system Ruby. Install Homebrew Ruby, put it on `PATH`, then install Bundler 4.0.17:

```bash
brew install ruby
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
gem install bundler -v 4.0.17
bundle install
```

### `python: command not found`

Before `.venv` exists, use `python3`:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

After activation, use `python`.

### `No such file or directory - pdfinfo`

Install Poppler:

```bash
brew install poppler
```

### `No such file or directory - qpdf`

Install qpdf:

```bash
brew install qpdf
```

### `SSL: CERTIFICATE_VERIFY_FAILED` while Docling downloads models

Update the Python CA bundle first:

```bash
python -m pip install --upgrade certifi
```

If Python still cannot validate HTTPS using your machine's trusted certificates:

```bash
python -m pip install truststore pip-system-certs
deactivate
source .venv/bin/activate
```

Do not disable TLS certificate verification as a workaround.

### Hugging Face `Byte range not sequential`

Disable the Xet downloader and retry:

```bash
export HF_HUB_DISABLE_XET=1
```

Optionally clear only the Xet cache before retrying:

```bash
rm -rf ~/.cache/huggingface/xet
```

## Test

```bash
ruby -Itest test/test_page_marker.rb
ruby -Itest test/test_assembler.rb
ruby -Itest test/test_validator.rb
```

Or run the full test suite:

```bash
bundle exec rake test
```

## Current scope

This first pass deliberately processes one PDF page at a time so every output section receives an exact `<!-- PDF Page N -->` marker. That is slower than whole-document conversion but creates a simple, auditable baseline for the pilot.

The converter does not yet:

- compare output against the existing hand-reviewed LLM Edition;
- describe maps or artwork beyond extraction placeholders;
- generically reconstruct dense table semantics when neither backend preserves them;
- implement a PyMuPDF4LLM comparison adapter;
- retain structured Docling JSON alongside Markdown.

Those should only be added after the fixture reveals a concrete need.


# Steps to test/run smoke test:

## Normal Startup
```bash
source .venv/bin/activate
```

```bash
OMP_NUM_THREADS=2 && bin/convert ~/Library/CloudStorage/ProtonDrive-dtnorris@pm.me-folder/<pdf> --title "<title>" --output-dir build
```
(should run in about 1 min)


```bash
bundle exec rake test
```
