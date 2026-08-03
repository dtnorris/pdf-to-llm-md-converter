# pdf-to-llm-md-converter

A Ruby-first pilot for converting PDF books into page-addressable Markdown suitable for downstream editorial and LLM review.

Ruby owns orchestration, page splitting, canonical page markers, assembly, and validation. Docling is invoked through its command-line interface and can later be replaced behind the adapter boundary.

## Requirements

- Ruby 3.2+
- Bundler
- Poppler utilities: `pdfinfo` and `pdfseparate`
- Python environment with the `docling` CLI installed

Docling's official CLI supports Markdown output and image placeholders. The command is configurable in `config/conversion.yml` rather than embedded in application code.

## Setup

```bash
bundle install
python -m pip install docling
```

Verify dependencies:

```bash
ruby --version
pdfinfo -v
docling --help
```

## Convert the fixture

```bash
bin/convert fixtures/labyrinth_sample.pdf \
  --title "Labyrinth Adventures — Pilot Sample" \
  --output-dir build
```

Convert a limited range:

```bash
bin/convert fixtures/labyrinth_sample.pdf --from 3 --to 8
```

## Test

```bash
ruby -Itest test/test_page_marker.rb
ruby -Itest test/test_assembler.rb
ruby -Itest test/test_validator.rb
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


# Steps to test/run smoke test:

```bash
OMP_NUM_THREADS=2 && time bin/convert fixtures/labyrinth_sample_15_pages.pdf --title "Labyrinth Benchmark" --output-dir build
```
(should run in about 1 min)


```bash
bundle exec rake test
```
