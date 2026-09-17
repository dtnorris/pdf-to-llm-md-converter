# Apple Vision experimental backend

This backend is intentionally opt-in. The existing `bin/convert` + Docling path
is unchanged.

The experiment keeps the converter's existing qpdf page splitting, page markers,
assembly, validation, progress reporting, and front matter. It swaps only the
per-page extraction layer:

1. render the already-split page at 300 DPI;
2. run macOS Vision text recognition in accurate English mode;
3. keep normalized bounding boxes for every recognized observation;
4. remove only extreme photographed-page edge bleed;
5. infer one, two, or three dominant text regions automatically with weighted
   one-dimensional clustering;
6. reject a proposed extra column unless it has enough mass, separation, and
   fit improvement;
7. suppress isolated numeric map labels away from text regions; and
8. emit regions left-to-right and text top-to-bottom within each region.

Every experimental page begins with an HTML diagnostic comment and each inferred
region has a `VISION REGION` comment. The adapter also writes the raw Vision TSV
and a JSON ordering diagnostic into its per-page output directory.

## Run through the normal converter pipeline

```bash
bin/convert-vision-experimental /path/to/book.pdf \
  --from 38 --to 39 \
  --title "Vision experimental smoke" \
  --output-dir build/vision-smoke
```

The experimental config defaults to one worker. Do not increase concurrency
until local wall-clock measurements show that repeated Swift startup is worth
bursting.

## Fixed Micro Dungeons morphology panel

The backend contains no page-specific layout profiles. To test the same code
unchanged across the previously adjudicated morphology panel:

```bash
bin/vision-layout-pilot /Users/davidnorris/code/Micro-Dungeons-Annual-2024.pdf \
  --pages 38,39,76,77,79,85,88,92,118,119,158,167,169,192,194 \
  --output-dir build/vision-microdungeons-panel
```

That panel intentionally contains:

- one-column continuation layouts: 118, 119, 158;
- ordinary two-column layouts: 39, 76, 192, 194;
- map-heavy two-column layouts: 38, 77, 79, 88, 92;
- three-column/stat-block layout: 85; and
- photographed neighboring-page bleed: 92, 119, 167, 169.

The pilot prints word count, inferred region count, edge drops, and map-noise
drops, and preserves page Markdown plus raw Vision TSV/JSON diagnostics for
semantic adjudication.

This is not yet the default conversion path and should not be used to overwrite
canonical Markdown until the fixed panel and a larger false-negative sample have
been reviewed.
