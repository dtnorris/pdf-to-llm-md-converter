# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter"
require_relative "../lib/extraction_result"

class ConverterExtractionQualityTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      1
    end

    def pdf_page_labels(_input, _pages)
      { 1 => "1" }
    end

    def extract_page(input:, page:, tmpdir:)
      path = File.join(tmpdir, "page-#{page}.pdf")
      File.write(path, "%PDF fake isolated page")
      path
    end
  end

  class MetadataAdapter
    def convert_with_metadata(input:, output_dir:)
      FileUtils.mkdir_p(output_dir)
      PdfToLlmMd::ExtractionResult.new(
        markdown: "# Adventure title only",
        backend: "apple-vision",
        diagnostics: {
          "recognized_characters" => 600,
          "table_like" => false
        }
      )
    end
  end

  def test_conversion_result_keeps_structural_and_extraction_quality_separate
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")
      File.write(input, "%PDF fake")
      File.write(
        config_path,
        {
          "processing" => { "parallel_workers" => 1 },
          "output" => {
            "filename_suffix" => "_LLM_Edition.md",
            "include_front_matter" => true,
            "conversion_label" => "test"
          },
          "validation" => {
            "require_page_markers" => true,
            "minimum_characters_per_page" => 0,
            "maximum_blank_page_ratio" => 1.0,
            "flag_patterns" => []
          }
        }.to_yaml
      )

      result = TestConverter.new(
        config_path: config_path,
        adapter: MetadataAdapter.new
      ).convert(input: input, output_dir: output_dir)

      assert result.validation.valid
      refute result.extraction_quality.valid
      assert_equal 1, result.extraction_quality.issues.first.page
    end
  end
end
