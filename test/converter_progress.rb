# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"

require_relative "../lib/converter"

class ConverterProgressTest < Minitest::Test
  class FakeAdapter
    def convert(input:, output_dir:)
      FileUtils.mkdir_p(output_dir)
      "# Converted #{File.basename(input)}"
    end
  end

  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      3
    end

    def extract_page(input:, page:, tmpdir:)
      path = File.join(tmpdir, "page-#{page}.pdf")
      File.write(path, "fake PDF page #{page}")
      path
    end
  end

  def test_reports_pdf_inspection_and_page_conversion_progress
    Dir.mktmpdir do |tmpdir|
      config_path = File.join(tmpdir, "conversion.yml")
      input_path = File.join(tmpdir, "sample.pdf")
      output_dir = File.join(tmpdir, "build")

      File.write(
        config_path,
        {
          "output" => {
            "filename_suffix" => "_LLM_Edition.md"
          },
          "validation" => {}
        }.to_yaml
      )

      File.write(input_path, "%PDF fake fixture")

      messages = []

      converter = TestConverter.new(
        config_path: config_path,
        adapter: FakeAdapter.new
      )

      converter.convert(
        input: input_path,
        output_dir: output_dir,
        progress: ->(message) { messages << message }
      )

      assert_equal(
        [
          "Inspecting PDF: 3 pages",
          "Converting page 1 of 3...",
          "Converting page 2 of 3...",
          "Converting page 3 of 3..."
        ],
        messages
      )
    end
  end
end
