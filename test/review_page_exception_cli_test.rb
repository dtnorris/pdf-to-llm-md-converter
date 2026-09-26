# frozen_string_literal: true

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "minitest/autorun"
require_relative "../lib/conversion_receipt"

class ReviewPageExceptionCliTest < Minitest::Test
  Validation = Struct.new(:valid, :errors, :warnings, :stats, keyword_init: true)
  QualityIssue = Struct.new(:page, :backend, :reason, :diagnostics, keyword_init: true)
  Quality = Struct.new(:valid, :issues, :pages, keyword_init: true)
  Result = Struct.new(:output_path, :validation, :extraction_quality, :pages, keyword_init: true)

  COMMAND = File.expand_path("../bin/review-page-exception", __dir__)

  def test_final_accepted_exception_prints_exact_af_catalog_resume_command
    Dir.mktmpdir do |dir|
      source = File.join(dir, "Owned Book (final).pdf")
      output = File.join(dir, "Owned_Book_LLM_Edition.md")
      receipt = write_receipt(source:, output:)
      adventure_finder_root = File.join(dir, "adventure finder")

      stdout, stderr, status = Open3.capture3(
        { "AF_ADVENTURE_FINDER_ROOT" => adventure_finder_root },
        RbConfig.ruby,
        COMMAND,
        receipt,
        "--page", "1",
        "--reason", "Reviewed image-only page",
        "--accept-exception"
      )

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "State: READY_WITH_EXCEPTIONS"
      assert_includes stdout, "Unresolved extraction-quality pages: none"
      assert_includes stdout, "Next command:"
      assert_includes stdout, "cd #{Shellwords.escape(adventure_finder_root)}"
      assert_includes stdout,
        "#{Shellwords.escape(File.join(adventure_finder_root, 'bin', 'af-catalog'))} #{Shellwords.escape(source)}"
    end
  end

  def test_structurally_invalid_receipt_does_not_route_downstream_after_exception_review
    Dir.mktmpdir do |dir|
      source = File.join(dir, "book.pdf")
      output = File.join(dir, "Book_LLM_Edition.md")
      receipt = write_receipt(source:, output:, structural_valid: false)

      stdout, stderr, status = Open3.capture3(
        { "AF_ADVENTURE_FINDER_ROOT" => File.join(dir, "adventure-finder") },
        RbConfig.ruby,
        COMMAND,
        receipt,
        "--page", "1",
        "--reason", "Reviewed page-specific extraction issue",
        "--accept-exception"
      )

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "State: INVALID"
      assert_includes stdout,
        "Next command: none until the remaining conversion/structural validation failure is resolved."
      refute_includes stdout, "bin/af-catalog"
    end
  end

  private

  def write_receipt(source:, output:, structural_valid: true)
    File.write(source, "%PDF source")
    File.write(output, "<!-- PDF Page 1 -->\n[image]\n")

    issue = QualityIssue.new(
      page: 1,
      backend: "apple-vision",
      reason: "extracted text covers only 0.0% of Vision recognized text",
      diagnostics: { "recognized_characters" => 450, "extracted_characters" => 0 }
    )
    quality = Quality.new(
      valid: false,
      issues: [issue],
      pages: { 1 => { "backend" => "apple-vision" } }
    )
    validation = Validation.new(
      valid: structural_valid,
      errors: structural_valid ? [] : ["fixture structural failure"],
      warnings: [],
      stats: { expected_pages: 1, page_markers: 1 }
    )
    result = Result.new(
      output_path: output,
      validation:,
      extraction_quality: quality,
      pages: [1]
    )

    PdfToLlmMd::ConversionReceipt.write(input_path: source, result:).path
  end
end
