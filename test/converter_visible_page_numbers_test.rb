# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter"

class ConverterVisiblePageNumbersTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    attr_reader :visible_pages_requested

    private

    def pdf_page_count(_input)
      3
    end

    def pdf_page_labels(_input, _pages)
      { 2 => "ii" }
    end

    def pdf_visible_page_numbers(_input, pages, _total_pages)
      @visible_pages_requested = pages
      { 1 => "1", 2 => "2", 3 => "3" }
    end

    def extract_pages(input:, pages:, progress: nil)
      pages.to_h { |page| [page, "Page #{page} content"] }
    end
  end

  def test_visible_numbers_fill_only_missing_metadata_labels
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")
      File.write(input, "%PDF fake fixture")
      File.write(config_path, {
        "output" => { "filename_suffix" => "_LLM_Edition.md" },
        "validation" => {
          "require_page_markers" => true,
          "minimum_characters_per_page" => 0,
          "maximum_blank_page_ratio" => 1.0,
          "flag_patterns" => []
        }
      }.to_yaml)

      converter = TestConverter.new(config_path: config_path, adapter: Object.new)
      result = converter.convert(input: input, output_dir: output_dir)
      markdown = File.read(result.output_path)

      assert_equal [1, 3], converter.visible_pages_requested
      assert_includes markdown, "<!-- PDF Page 1 -->\n<!-- Printed Page 1 -->"
      assert_includes markdown, "<!-- PDF Page 2 -->\n<!-- PDF Page Label ii -->"
      assert_includes markdown, "<!-- PDF Page 3 -->\n<!-- Printed Page 3 -->"
      refute_includes markdown, "<!-- Printed Page 2 -->"
    end
  end
end
