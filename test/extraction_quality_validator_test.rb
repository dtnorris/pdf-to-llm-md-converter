# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/extraction_quality_validator"
require_relative "../lib/extraction_result"

class ExtractionQualityValidatorTest < Minitest::Test
  def test_rejects_title_only_output_when_vision_saw_substantive_text
    result = validate(
      38 => extraction(
        markdown: "# The Adventure\nShort title only",
        backend: "apple-vision",
        diagnostics: { "recognized_characters" => 620, "table_like" => false }
      )
    )

    refute result.valid
    assert_includes result.issues.first.reason, "Vision recognized text"
  end

  def test_normal_substantive_page_passes
    text = ("Substantive adventure room text with clues encounters and outcomes. " * 10)
    result = validate(
      39 => extraction(
        markdown: text,
        backend: "apple-vision",
        diagnostics: { "recognized_characters" => 500, "table_like" => false }
      )
    )

    assert result.valid
  end

  def test_sparse_legitimate_page_is_not_rejected_for_low_word_count_alone
    result = validate(
      2 => extraction(
        markdown: "# Credits",
        backend: "apple-vision",
        diagnostics: { "recognized_characters" => 12, "table_like" => false }
      )
    )

    assert result.valid
  end

  def test_detects_silent_partial_loss_against_native_source_text
    result = validate(
      88 => extraction(
        markdown: "Recovered text " * 20,
        backend: "docling",
        diagnostics: { "source_native_characters" => 900 }
      )
    )

    refute result.valid
    assert_includes result.issues.first.reason, "native source text"
  end

  def test_rejects_table_like_vision_flattening
    result = validate(
      187 => extraction(
        markdown: "CR AC HP Attack Damage " * 40,
        backend: "apple-vision",
        diagnostics: { "recognized_characters" => 500, "table_like" => true }
      )
    )

    refute result.valid
    assert result.issues.any? { |issue| issue.reason.include?("table-like geometry") }
  end

  def test_docling_table_fallback_can_pass_when_coverage_is_healthy
    result = validate(
      187 => extraction(
        markdown: "| CR | AC | HP | Attack |\n|---|---|---|---|\n" + ("| 5 | 16 | 80 | claw |\n" * 12),
        backend: "docling",
        diagnostics: {
          "source_native_characters" => 0,
          "recognized_characters" => 180,
          "vision_table_like" => true,
          "table_fallback_safe" => true
        }
      )
    )

    assert result.valid
  end

  private

  def validate(page_results)
    PdfToLlmMd::ExtractionQualityValidator.new(config: {}).validate(
      page_results: page_results
    )
  end

  def extraction(markdown:, backend:, diagnostics:)
    PdfToLlmMd::ExtractionResult.new(
      markdown: markdown,
      backend: backend,
      diagnostics: diagnostics
    )
  end
end
