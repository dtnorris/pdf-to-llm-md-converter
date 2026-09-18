# Apple Vision backend and automatic scanned-page routing

Apple Vision is now one of the backends available to the normal `bin/convert`
path. The default `auto` mode keeps text-native pages on Docling and uses Vision
for effectively image-only/scanned pages on supported macOS systems.

The older `bin/convert-vision-experimental` entry point remains available as an
explicit all-Vision smoke/debug path. It is no longer the only way normal
conversion can reach Apple Vision.

The Vision backend keeps the converter's existing qpdf page splitting, page
markers, assembly, structural validation, progress reporting, and front matter.
For each scanned page it:

1. renders the already-split page at 300 DPI;
2. runs macOS Vision text recognition in accurate English mode;
3. keeps normalized bounding boxes for every recognized observation;
4. removes only extreme photographed-page edge bleed;
5. infers one, two, or three dominant text regions with weighted clustering;
6. suppresses isolated numeric map labels away from text regions;
7. records recognized/kept character counts for the extraction-quality gate; and
8. detects strong repeated multi-cell row geometry as `table_like`.

Every Vision page begins with an HTML diagnostic comment and each inferred region
has a `VISION REGION` comment. The adapter also writes the raw Vision TSV and a
JSON ordering diagnostic into its per-page output directory.

## Automatic routing rule

The thresholds live in `config/conversion.yml` under `auto_backend`.

- `pdftotext` native alphanumeric text >= 80 characters: use Docling.
- 20–79 native alphanumeric characters with at least one PDF font: use Docling.
- otherwise: treat the page as effectively scanned/image-only and use Apple
  Vision.

If the source-text inspection itself cannot run, auto mode fails closed. If a
scanned page needs Vision but Vision is unavailable, auto mode also fails closed
rather than silently using the known-weaker Docling OCR/layout path.

Explicit overrides are available through normal conversion:

```bash
bin/convert /path/to/book.pdf --backend auto
bin/convert /path/to/book.pdf --backend docling
bin/convert /path/to/book.pdf --backend apple-vision
```

## Dense tables

Vision's prose-column reading order is not treated as semantically safe for dense
tables. A page is flagged table-like only from repeated row geometry containing
at least four short cells across a broad horizontal span, repeated across enough
rows. This deliberately does not classify ordinary three-column/stat-block
layouts merely because they use three columns.

For a scanned table-like page, auto mode runs Docling as a fallback. The fallback
is accepted only when Docling emits repeated Markdown/HTML table rows and retains
at least 60% of the text characters Vision recognized. If those conditions are
not met, the Vision result is marked review-required and the extraction-quality
gate fails the conversion. There are no book- or page-number-specific exceptions.

## Extraction-quality gate

This is separate from the existing structural validator. It does not raise the
global minimum page length. Instead it fails severe reference-relative collapse:

- text-native pages whose extraction retains less than 55% of sufficiently
  substantial native PDF text, with at least 100 characters missing;
- Vision pages whose emitted text retains less than 55% of sufficiently
  substantial Vision-recognized text, with at least 100 characters missing; and
- table-like pages still selected as Apple Vision prose output.

Sparse covers, separators, map-heavy pages, and other genuinely sparse pages are
therefore not rejected merely because they contain few words.

## Micro Dungeons morphology panel

The backend contains no page-specific layout profiles. The fixed safety panel is:

```text
38,39,85,88,92,187,204
```

Pages 38, 39, 85, 88, and 92 should produce materially usable adventure text.
Pages 187 and 204 must either select a structurally adequate Docling table
fallback or fail extraction quality for review; flattened Vision table prose is
not a clean pass.

The separate `bin/vision-layout-pilot` remains useful for broader Vision-only
morphology diagnostics. This routing/gate work does not claim to solve every PDF
layout or reconstruct arbitrary tables.
