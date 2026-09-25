# Persistent page-extraction cache

The page cache is an optional repair/iteration path. Normal `bin/convert`
behavior is unchanged.

Use the cache-enabled wrapper when repeated extraction would waste time:

```bash
bin/convert-cached input.pdf \
  --title "Document Title" \
  --output-dir build/document
```

The wrapper delegates to the existing `bin/convert` command after preloading the
cache extension, so the existing conversion, validation, receipt, and exit-status
behavior remains authoritative.

## Cache location

By default cached page extraction results live beneath:

```text
<OUTPUT_DIR>/.page-cache/
```

`build/` is already ignored by this repository. Cache data is runtime/build
state and should not be committed or copied into the canonical Markdown corpus.

A different location can be selected with:

```bash
bin/convert-cached input.pdf \
  --output-dir build/document \
  --page-cache-dir /path/to/cache
```

## Reuse and invalidation contract

A cache namespace is derived from:

- SHA-256 of the complete source PDF;
- SHA-256 of the exact conversion configuration bytes; and
- requested adapter identity (`auto`, `docling`, `apple-vision`, or the adapter
  class identity for a programmatic caller).

Each cached page repeats that identity and carries a SHA-256 of its cached
Markdown. Invalid or corrupt cache entries become misses and are re-extracted.

Changed source bytes, conversion configuration, or requested backend therefore
cannot reuse a prior namespace.

Title, page-range selection, and printed-page offset do not affect page
extraction itself and are intentionally not cache keys.

## Targeted repair

After fixing or investigating extraction behavior for one page, refresh only
that page:

```bash
bin/convert-cached input.pdf \
  --title "Document Title" \
  --output-dir build/document \
  --refresh-page 57
```

`--refresh-page` is repeatable.

The previous entry for a refreshed page is deleted before re-extraction. If the
new extraction fails, a later run cannot silently fall back to the old result.

Unchanged pages continue to come from the validated cache namespace.

## Bypass

For a deliberately clean comparison run:

```bash
bin/convert-cached input.pdf --no-page-cache
```

This delegates to the ordinary converter without reading or writing page-cache
entries. `--refresh-page` cannot be combined with `--no-page-cache`.

Running `bin/convert` directly also remains the ordinary uncached path.

## Reproducibility boundary

The cache fingerprints source bytes, configuration bytes, and adapter selection.
It intentionally does not fingerprint the converter source tree or installed
external model/tool binaries. This permits a targeted code repair to refresh one
affected page while retaining the previously accepted extraction of unaffected
pages.

When validating a broad extraction implementation change or upgraded external
dependency, use the ordinary uncached `bin/convert`, use `--no-page-cache`, or
explicitly refresh every page whose extraction must be reevaluated.

The source PDF is hashed again after cached extraction. If it changes or
disappears during the run, the active namespace is deleted and conversion fails.
