# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/conversion_receipt"

class ConversionReceiptTest < Minitest::Test
  Validation = Struct.new(:valid, :errors, :warnings, :stats, keyword_init: true)
  QualityIssue = Struct.new(:page, :backend, :reason, :diagnostics, keyword_init: true)
  Quality = Struct.new(:valid, :issues, :pages, keyword_init: true)
  Result = Struct.new(:output_path, :validation, :extraction_quality, :pages, keyword_init: true)

  def test_quality_failure_is_retained_as_not_ready_until_explicit_page_review
    Dir.mktmpdir do |tmpdir|
      source = File.join(tmpdir, "book.pdf")
      output = File.join(tmpdir, "Book_LLM_Edition.md")
      File.write(source, "%PDF source")
      File.write(output, "<!-- PDF Page 1 -->\n[image]\n")

      receipt = PdfToLlmMd::ConversionReceipt.write(
        input_path: source,
        result: result_with_quality_issue(output)
      )

      assert_equal "needs_page_review", receipt.payload.fetch("state")
      refute receipt.payload.fetch("downstream_ready")
      assert_equal [1], receipt.payload.dig("extraction_quality", "issues").map { |issue| issue.fetch("page") }
      assert File.file?(receipt.path)

      preview = PdfToLlmMd::ConversionReceipt.inspect_page(path: receipt.path, page: 1)
      assert_equal 1, preview.fetch("issues").length

      reviewed = PdfToLlmMd::ConversionReceipt.accept_page_exception(
        path: receipt.path,
        page: 1,
        reason: "Map-only page; no substantive prose or table content is expected"
      )

      assert_equal "ready_with_exceptions", reviewed.payload.fetch("state")
      assert reviewed.payload.fetch("downstream_ready")
      assert_empty reviewed.unresolved_pages
      assert_equal 1, reviewed.payload.fetch("page_exceptions").length
      assert_equal "<!-- PDF Page 1 -->\n[image]\n", File.read(output)
    end
  end

  def test_review_refuses_unflagged_page
    Dir.mktmpdir do |tmpdir|
      source, output, receipt = write_fixture(tmpdir)
      error = assert_raises(PdfToLlmMd::ConversionReceipt::Error) do
        PdfToLlmMd::ConversionReceipt.inspect_page(path: receipt.path, page: 2)
      end

      assert_match(/No unresolved extraction-quality issues/, error.message)
      assert File.file?(source)
      assert File.file?(output)
    end
  end

  def test_review_refuses_changed_markdown
    Dir.mktmpdir do |tmpdir|
      _source, output, receipt = write_fixture(tmpdir)
      File.write(output, "changed after conversion")

      error = assert_raises(PdfToLlmMd::ConversionReceipt::Error) do
        PdfToLlmMd::ConversionReceipt.inspect_page(path: receipt.path, page: 1)
      end

      assert_match(/Markdown output changed since conversion/, error.message)
    end
  end

  def test_page_exception_cannot_override_structural_failure
    Dir.mktmpdir do |tmpdir|
      source = File.join(tmpdir, "book.pdf")
      output = File.join(tmpdir, "Book_LLM_Edition.md")
      File.write(source, "%PDF source")
      File.write(output, "<!-- PDF Page 1 -->\n[image]\n")

      result = result_with_quality_issue(output)
      result.validation = Validation.new(
        valid: false,
        errors: ["Missing page markers: 2"],
        warnings: [],
        stats: { expected_pages: 2 }
      )
      result.pages = [1, 2]

      receipt = PdfToLlmMd::ConversionReceipt.write(input_path: source, result: result)
      assert_equal "invalid", receipt.payload.fetch("state")

      reviewed = PdfToLlmMd::ConversionReceipt.accept_page_exception(
        path: receipt.path,
        page: 1,
        reason: "Reviewed page-specific extraction issue"
      )

      assert_equal "invalid", reviewed.payload.fetch("state")
      refute reviewed.payload.fetch("downstream_ready")
    end
  end

  private

  def write_fixture(tmpdir)
    source = File.join(tmpdir, "book.pdf")
    output = File.join(tmpdir, "Book_LLM_Edition.md")
    File.write(source, "%PDF source")
    File.write(output, "<!-- PDF Page 1 -->\n[image]\n")
    receipt = PdfToLlmMd::ConversionReceipt.write(
      input_path: source,
      result: result_with_quality_issue(output)
    )
    [source, output, receipt]
  end

  def result_with_quality_issue(output)
    issue = QualityIssue.new(
      page: 1,
      backend: "apple-vision",
      reason: "extracted text covers only 0.0% of Vision recognized text",
      diagnostics: { "recognized_characters" => 450, "extracted_characters" => 0 }
    )
    quality = Quality.new(
      valid: false,
      issues: [issue],
      pages: {
        1 => {
          "backend" => "apple-vision",
          "recognized_characters" => 450,
          "extracted_characters" => 0
        }
      }
    )
    validation = Validation.new(
      valid: true,
      errors: [],
      warnings: [],
      stats: { expected_pages: 1, page_markers: 1 }
    )

    Result.new(
      output_path: output,
      validation: validation,
      extraction_quality: quality,
      pages: [1]
    )
  end
end
