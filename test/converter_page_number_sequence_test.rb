# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter"

class ConverterPageNumberSequenceTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      30
    end

    def pdf_page_labels(_input, _pages)
      {}
    end

    def pdf_visible_page_numbers(_input, _pages, _total_pages)
      { 25 => "22", 26 => "23" }
    end

    def pdf_visual_page_numbers(_input, _pages, _total_pages, _known_labels)
      { 27 => "24" }
    end

    def extract_pages(input:, pages:, progress: nil)
      pages.to_h { |page| [page, "Page #{page} content"] }
    end
  end

  def test_converter_fills_short_missing_stretches_after_direct_detectors_establish_sequence
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
      result = converter.convert(
        input: input,
        output_dir: output_dir,
        from_page: 24,
        to_page: 30
      )
      markdown = File.read(result.output_path)

      (24..30).each do |physical_page|
        printed_page = physical_page - 3
        assert_includes(
          markdown,
          "<!-- PDF Page #{physical_page} -->\n<!-- Printed Page #{printed_page} -->"
        )
      end
    end
  end
end
