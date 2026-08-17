# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"

require_relative "../lib/converter"

class ConverterTitleTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      1
    end

    def pdf_page_labels(_input, _pages)
      { 1 => "1" }
    end

    def extract_pages(input:, pages:, progress: nil)
      pages.to_h { |page| [page, "Page #{page} content"] }
    end
  end

  def test_title_sets_front_matter_and_output_filename
    with_converter(input_name: "Original Book.pdf") do |converter, input, output_dir|
      result = converter.convert(
        input: input,
        output_dir: output_dir,
        title: "Renamed Adventure"
      )
      markdown = File.read(result.output_path)

      assert_equal(
        "Renamed_Adventure_LLM_Edition.md",
        File.basename(result.output_path)
      )
      assert_includes markdown, "title: Renamed Adventure"
    end
  end

  def test_omitting_title_preserves_input_basename_behavior
    with_converter(input_name: "Original Book.PDF") do |converter, input, output_dir|
      result = converter.convert(input: input, output_dir: output_dir)
      markdown = File.read(result.output_path)

      assert_equal(
        "Original_Book_LLM_Edition.md",
        File.basename(result.output_path)
      )
      assert_includes markdown, "title: Original Book"
    end
  end

  def test_title_is_sanitized_for_use_as_a_filename
    with_converter(input_name: "Original.pdf") do |converter, input, output_dir|
      result = converter.convert(
        input: input,
        output_dir: output_dir,
        title: "A / Strange\\Title\nTest"
      )

      assert_equal(
        "A_Strange_Title_Test_LLM_Edition.md",
        File.basename(result.output_path)
      )
    end
  end

  private

  def with_converter(input_name:)
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, input_name)
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")

      File.write(input, "%PDF fake fixture")
      File.write(config_path, {
        "processing" => {
          "normalize_line_endings" => true,
          "collapse_excess_blank_lines" => true
        },
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
      }.to_yaml)

      converter = TestConverter.new(
        config_path: config_path,
        adapter: Object.new
      )
      yield converter, input, output_dir
    end
  end
end
