# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"

require_relative "../lib/converter"

class ConverterProgressEventsTest < Minitest::Test
  class FakeAdapter
    def convert(input:, output_dir:)
      FileUtils.mkdir_p(output_dir)
      "# Converted #{File.basename(input)}"
    end
  end

  class RecordingReporter
    attr_reader :events

    def initialize
      @events = []
    end

    def inspect_pdf(total_pages:)
      @events << [:inspect_pdf, total_pages]
    end

    def start_conversion(total_pages:)
      @events << [:start_conversion, total_pages]
    end

    def advance(current:, total_pages:)
      @events << [:advance, current, total_pages]
    end

    def validation(result:)
      @events << [:validation, result.valid]
    end
  end

  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      3
    end

    def extract_page(input:, page:, tmpdir:)
      output_path = File.join(tmpdir, "page-#{page}.pdf")
      File.write(output_path, "fake PDF page #{page}")
      output_path
    end
  end

  def test_emits_structured_progress_events
    Dir.mktmpdir do |tmpdir|
      input_path = File.join(tmpdir, "sample.pdf")
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")

      File.write(input_path, "%PDF fake fixture")

      File.write(
        config_path,
        {
          "output" => {
            "filename_suffix" => "_LLM_Edition.md"
          },
          "validation" => {
            "require_page_markers" => true,
            "minimum_characters_per_page" => 0,
            "maximum_blank_page_ratio" => 1.0,
            "flag_patterns" => []
          }
        }.to_yaml
      )

      reporter = RecordingReporter.new

      converter = TestConverter.new(
        config_path: config_path,
        adapter: FakeAdapter.new
      )

      result = converter.convert(
        input: input_path,
        output_dir: output_dir,
        progress: reporter
      )

      assert result.validation.valid

      assert_equal(
        [
          [:inspect_pdf, 3],
          [:start_conversion, 3],
          [:advance, 1, 3],
          [:advance, 2, 3],
          [:advance, 3, 3],
          [:validation, true]
        ],
        reporter.events
      )
    end
  end

  def test_reports_selected_range_total_in_progress_bar
    Dir.mktmpdir do |tmpdir|
      input_path = File.join(tmpdir, "sample.pdf")
      output_dir = File.join(tmpdir, "build")
      config_path = File.join(tmpdir, "conversion.yml")

      File.write(input_path, "%PDF fake fixture")

      File.write(
        config_path,
        {
          "output" => {
            "filename_suffix" => "_LLM_Edition.md"
          },
          "validation" => {
            "require_page_markers" => true,
            "minimum_characters_per_page" => 0,
            "maximum_blank_page_ratio" => 1.0,
            "flag_patterns" => []
          }
        }.to_yaml
      )

      reporter = RecordingReporter.new

      converter = TestConverter.new(
        config_path: config_path,
        adapter: FakeAdapter.new
      )

      converter.convert(
        input: input_path,
        output_dir: output_dir,
        from_page: 2,
        to_page: 3,
        progress: reporter
      )

      assert_includes reporter.events, [:inspect_pdf, 3]
      assert_includes reporter.events, [:start_conversion, 2]
      assert_includes reporter.events, [:advance, 1, 2]
      assert_includes reporter.events, [:advance, 2, 2]
    end
  end
end
