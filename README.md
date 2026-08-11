# pdf-to-llm-md-converter

A Ruby-first pilot for converting PDF books into page-addressable Markdown suitable for downstream editorial and LLM review.

Ruby owns orchestration, page splitting, canonical page markers, assembly, and validation. Docling is invoked through its command-line interface and can later be replaced behind the adapter boundary.

## Requirements

- macOS with Homebrew (commands below assume Apple Silicon; Intel paths may differ)
- Ruby 3.2+
- Bundler 4.0.17 (the version recorded in `Gemfile.lock`)
- Python 3.10+
- Poppler utilities: `pdfinfo` and `pdfseparate`
- `qpdf`
- Python environment with the `docling` CLI installed

Docling's official CLI supports Markdown output and image placeholders. The command is configurable in `config/conversion.yml` rather than embedded in application code.

## Fresh-machine setup (macOS)

These steps are intended to work from a clean macOS development environment and avoid relying on Apple's system Ruby.

### 1. Install Homebrew dependencies

```bash
brew install ruby python poppler qpdf
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
bundle install
```

Do not install Bundler into Apple's system Ruby with `sudo gem install`.

### 3. Create the Python virtual environment

Homebrew exposes Python as `python3` outside a virtual environment:

```bash
python3 --version
python3 -m venv .venv
source .venv/bin/activate
```

Once activated, `python` should resolve inside `.venv`:

```bash
which python
python --version
```

### 4. Install Docling

```bash
python -m pip install --upgrade pip
python -m pip install docling
```

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

### 5. Verify all runtime dependencies

Run these before the first conversion:

```bash
ruby --version
bundle --version
python --version
docling --help
pdfinfo -v
pdfseparate -v
qpdf --version
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

The first Docling conversion may be significantly slower because model files are downloaded and initialized. Subsequent runs should reuse the local model cache.

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
- describe maps or artwork beyond Docling placeholders;
- repair malformed tables or reading order;
- implement a PyMuPDF4LLM comparison adapter;
- retain structured Docling JSON alongside Markdown.

Those should only be added after the fixture reveals a concrete need.
