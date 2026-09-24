# Conversion receipts and page-exception review

`bin/convert` writes the Markdown output before structural and extraction-quality
validation completes. This is intentional: failed output can be useful for diagnosis.
A failed quality gate therefore must not be mistaken for accepted downstream input.

Every completed conversion now writes a sibling receipt:

```text
<My_Title>_LLM_Edition.md
<My_Title>_LLM_Edition.conversion-receipt.json
```

The receipt binds the conversion to the SHA-256 and byte size of both the source PDF
and generated Markdown. It records structural validation, extraction-quality issues,
per-page diagnostics, and any explicitly reviewed page exceptions.

Receipt states are:

- `ready` — structural validation passed and there are no extraction-quality issues.
- `needs_page_review` — structural validation passed, but one or more page-specific
  extraction-quality issues remain unresolved. The Markdown is diagnostic output and
  is not ready for downstream use.
- `ready_with_exceptions` — every extraction-quality issue has been explicitly
  reviewed and accepted as a page-specific exception while the bound source and
  Markdown hashes still match.
- `invalid` — structural validation failed. Page exceptions cannot override this.

## Review a flagged page

Preview the receipt evidence first; this makes no changes:

```bash
bin/review-page-exception \
  build/My_Title_LLM_Edition.conversion-receipt.json \
  --page 57
```

The command shows the source PDF, Markdown path, backend, and unresolved reason(s) for
that page. After inspecting both the source page and generated Markdown, a reviewer can
record a supported exception explicitly:

```bash
bin/review-page-exception \
  build/My_Title_LLM_Edition.conversion-receipt.json \
  --page 57 \
  --reason "Map-only page; no substantive prose or table content is expected" \
  --accept-exception
```

An exception is bound to the exact source/output hashes and to the fingerprints of the
currently unresolved issues on that PDF page. The review command refuses to proceed if
either file changed, if the page has no unresolved extraction-quality issue, or if the
reason is blank. It modifies only the receipt; it never edits the Markdown or suppresses
future converter findings.

A new conversion regenerates the receipt from machine evidence and therefore clears
prior page exceptions. Downstream workflow should proceed only when
`downstream_ready` is `true` (`ready` or `ready_with_exceptions`).
