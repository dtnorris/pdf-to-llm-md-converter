# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter"

class ConverterPrintedPageOffsetTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      3
    end

    def pdf_page_labels(_input, _pages)
      raise "automatic PDF page-label detection should be bypassed"
    end

    def pdf_visible_page_numbers(_input, _pages, _total_pages)
      raise "automatic visible page-number detection should be bypassed"
    end

    def pdf_visual_page_numbers(_input, _pages, _total_pages, _known_labels, _progress = nil)
      raise "automatic visual page-number detection should be bypassed"
    end

    def pdf_inferred_page_numbers(_pages, _total_pages, _known_labels)
      raise "automatic inferred page-number detection should be bypassed"
    end

    def extract_pages(input:, pages:, progress: nil)
      pages.to_h { |page| [page, "Page #{page} content"] }
    end
  end

  def test_explicit_offset_maps_printed_pages_and_bypasses_detection
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")
      File.write(input, "%PDF fake fixture")
      File.write(config_path, {
        "output" => {
          "filename_suffix" => "_LLM_Edition.md",
          "include_front_matter" => true
        },
        "validation" => {
          "require_page_markers" => true,
          "minimum_characters_per_page" => 0,
          "maximum_blank_page_ratio" => 1.0,
          "flag_patterns" => []
        }
      }.to_yaml)

      converter = TestConverter.new(config_path: config_path, adapter: Object.new)
      result = converter.convert(
        input: input,
        output_dir: output_dir,
        printed_page_offset: -1
      )
      markdown = File.read(result.output_path)

      assert_includes markdown, "<!-- PDF Page 1 -->"
      refute_includes markdown, "<!-- Printed Page 0 -->"
      refute_includes markdown, "<!-- PDF Page Label 0 -->"
      assert_includes markdown, "<!-- PDF Page 2 -->\n<!-- Printed Page 1 -->"
      assert_includes markdown, "<!-- PDF Page 3 -->\n<!-- Printed Page 2 -->"
    end
  end
end
