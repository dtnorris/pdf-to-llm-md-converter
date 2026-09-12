# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/page_marker_relabeler"

class PageMarkerRelabelerTest < Minitest::Test
  def test_relabels_only_pagination_annotations
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.md")
      output = File.join(dir, "output.md")
      source = <<~MD
        # Book
        <!-- PDF Page 1 -->
        <!-- PDF Page Label cover -->
        Cover text
        <!-- PDF Page 2 -->
        <!-- Printed Page 99 -->
        Page one text
        <!-- PDF Page 3 -->
        Page two text
      MD
      File.write(input, source)

      result = PdfToLlmMd::PageMarkerRelabeler.relabel!(
        input: input,
        output: output,
        offset: -1,
        expected_pages: 3
      )

      assert_equal source, File.read(input)
      assert_equal 3, result.pdf_pages
      assert_equal 1, result.printed_markers_before
      assert_equal 1, result.page_labels_before
      assert_equal 2, result.printed_markers_after
      assert_equal <<~MD, File.read(output)
        # Book
        <!-- PDF Page 1 -->
        Cover text
        <!-- PDF Page 2 -->
        <!-- Printed Page 1 -->
        Page one text
        <!-- PDF Page 3 -->
        <!-- Printed Page 2 -->
        Page two text
      MD
    end
  end

  def test_refuses_non_contiguous_pdf_markers
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.md")
      output = File.join(dir, "output.md")
      File.write(input, "<!-- PDF Page 1 -->\na\n<!-- PDF Page 3 -->\nb\n")

      error = assert_raises(ArgumentError) do
        PdfToLlmMd::PageMarkerRelabeler.relabel!(input: input, output: output, offset: -1)
      end

      assert_includes error.message, "not contiguous"
      refute File.exist?(output)
    end
  end

  def test_refuses_duplicate_pdf_markers
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.md")
      output = File.join(dir, "output.md")
      File.write(input, "<!-- PDF Page 1 -->\na\n<!-- PDF Page 1 -->\nb\n")

      error = assert_raises(ArgumentError) do
        PdfToLlmMd::PageMarkerRelabeler.relabel!(input: input, output: output, offset: 0)
      end

      assert_includes error.message, "duplicate PDF page markers"
      refute File.exist?(output)
    end
  end

  def test_refuses_unexpected_page_count
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.md")
      output = File.join(dir, "output.md")
      File.write(input, "<!-- PDF Page 1 -->\na\n<!-- PDF Page 2 -->\nb\n")

      error = assert_raises(ArgumentError) do
        PdfToLlmMd::PageMarkerRelabeler.relabel!(
          input: input,
          output: output,
          offset: -1,
          expected_pages: 259
        )
      end

      assert_includes error.message, "expected 259 PDF page markers, found 2"
      refute File.exist?(output)
    end
  end

  def test_refuses_in_place_and_existing_output
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.md")
      output = File.join(dir, "output.md")
      File.write(input, "<!-- PDF Page 1 -->\na\n")
      File.write(output, "existing\n")

      assert_raises(ArgumentError) do
        PdfToLlmMd::PageMarkerRelabeler.relabel!(input: input, output: input, offset: 0)
      end
      assert_raises(ArgumentError) do
        PdfToLlmMd::PageMarkerRelabeler.relabel!(input: input, output: output, offset: 0)
      end
      assert_equal "existing\n", File.read(output)
    end
  end
end
