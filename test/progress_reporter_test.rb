# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../lib/progress_reporter"
require_relative "../lib/validator"

class ProgressReporterTest < Minitest::Test
  def test_renders_complete_progress_summary
    output = StringIO.new
    times = [0.0, 161.0]

    reporter = PdfToLlmMd::ProgressReporter.new(
      io: output,
      clock: -> { times.shift }
    )

    validation = PdfToLlmMd::ValidationResult.new(
      valid: true,
      errors: [],
      warnings: [],
      stats: {
        expected_pages: 225,
        page_markers: 225,
        missing_pages: [],
        duplicate_pages: [],
        short_pages: 0,
        flagged_pages: [12, 44, 91],
        characters: 100_000
      }
    )

    reporter.start
    reporter.inspect_pdf(total_pages: 225)
    reporter.start_conversion(total_pages: 225)
    reporter.advance(current: 225, total_pages: 225)
    reporter.validation(result: validation)
    reporter.finish(
      output_path: "build/Labyrinth_Adventures_LLM_Edition.md"
    )

    rendered = output.string

    assert_includes rendered, "Inspecting PDF: 225 pages"
    assert_includes rendered, "Converting..."
    assert_includes rendered, "[====================] 225/225"

    assert_includes rendered, "Validation"
    assert_includes rendered, "✓ 225 page markers"
    assert_includes rendered, "✓ no missing pages"
    assert_includes rendered, "✓ no duplicates"
    assert_includes rendered, "⚠ 3 pages contained OCR warnings"

    assert_includes rendered, "Finished in 2m 41s"
    assert_includes rendered, "Output:"
    assert_includes rendered,
                    "build/Labyrinth_Adventures_LLM_Edition.md"
  end

  def test_renders_clean_validation_summary
    output = StringIO.new
    reporter = PdfToLlmMd::ProgressReporter.new(io: output)

    validation = PdfToLlmMd::ValidationResult.new(
      valid: true,
      errors: [],
      warnings: [],
      stats: {
        expected_pages: 15,
        page_markers: 15,
        missing_pages: [],
        duplicate_pages: [],
        short_pages: 0,
        flagged_pages: [],
        characters: 5_000
      }
    )

    reporter.validation(result: validation)

    rendered = output.string

    assert_includes rendered, "✓ 15 page markers"
    assert_includes rendered, "✓ no missing pages"
    assert_includes rendered, "✓ no duplicates"
    assert_includes rendered, "✓ no OCR warnings"
  end

  def test_renders_missing_and_duplicate_pages
    output = StringIO.new
    reporter = PdfToLlmMd::ProgressReporter.new(io: output)

    validation = PdfToLlmMd::ValidationResult.new(
      valid: false,
      errors: [
        "Missing page markers: 2",
        "Duplicate page markers: 1"
      ],
      warnings: [],
      stats: {
        expected_pages: 2,
        page_markers: 2,
        missing_pages: [2],
        duplicate_pages: [1],
        short_pages: 0,
        flagged_pages: [],
        characters: 100
      }
    )

    reporter.validation(result: validation)

    rendered = output.string

    assert_includes rendered, "✗ missing pages: 2"
    assert_includes rendered, "✗ duplicate pages: 1"

    # These errors should not be printed a second time.
    assert_equal 1, rendered.scan("missing pages").length
    assert_equal 1, rendered.scan("duplicate pages").length
  end

  def test_uses_singular_warning_language
    output = StringIO.new
    reporter = PdfToLlmMd::ProgressReporter.new(io: output)

    validation = PdfToLlmMd::ValidationResult.new(
      valid: true,
      errors: [],
      warnings: [],
      stats: {
        expected_pages: 1,
        page_markers: 1,
        missing_pages: [],
        duplicate_pages: [],
        short_pages: 0,
        flagged_pages: [1],
        characters: 100
      }
    )

    reporter.validation(result: validation)

    assert_includes output.string,
                    "⚠ 1 page contained OCR warnings"
  end

  def test_formats_hours_minutes_and_seconds
    output = StringIO.new
    times = [0.0, 3_661.0]

    reporter = PdfToLlmMd::ProgressReporter.new(
      io: output,
      clock: -> { times.shift }
    )

    reporter.start
    reporter.finish(output_path: "build/output.md")

    assert_includes output.string, "Finished in 1h 1m 1s"
  end
end
