# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../lib/docling_adapter"

class DoclingAdapterOcrTest < Minitest::Test
  FakeStatus = Struct.new(:success_value, :exitstatus) do
    def success?
      success_value
    end
  end

  class RecordingAdapter < PdfToLlmMd::DoclingAdapter
    attr_reader :command

    private

    def run(command)
      @command = command

      output_dir = command.match(/--output "([^"]+)"/)[1]
      input = command.match(/docling "([^"]+)"/)[1]

      markdown_path = File.join(
        output_dir,
        "#{File.basename(input, File.extname(input))}.md"
      )

      FileUtils.mkdir_p(output_dir)
      File.write(markdown_path, "converted")

      ["", "", DoclingAdapterOcrTest::FakeStatus.new(true, 0)]
    end
  end

  def test_keeps_no_ocr_for_page_with_enough_extractable_text
    with_adapter do |adapter, input, output_dir|
      Open3.stub(
        :capture3,
        ["This page has enough embedded text.", "", FakeStatus.new(true, 0)]
      ) do
        adapter.convert(input: input, output_dir: output_dir)
      end

      assert_includes adapter.command, "--no-ocr"
    end
  end

  def test_enables_ocr_for_page_with_little_extractable_text
    with_adapter do |adapter, input, output_dir|
      Open3.stub(
        :capture3,
        ["short", "", FakeStatus.new(true, 0)]
      ) do
        adapter.convert(input: input, output_dir: output_dir)
      end

      refute_includes adapter.command, "--no-ocr"
    end
  end

  def test_enables_ocr_when_text_inspection_fails
    with_adapter do |adapter, input, output_dir|
      Open3.stub(
        :capture3,
        ["", "pdftotext failed", FakeStatus.new(false, 1)]
      ) do
        adapter.convert(input: input, output_dir: output_dir)
      end

      refute_includes adapter.command, "--no-ocr"
    end
  end

  def test_honors_configured_text_threshold
    with_adapter("ocr_min_text_characters" => 5) do |adapter, input, output_dir|
      Open3.stub(
        :capture3,
        ["12345", "", FakeStatus.new(true, 0)]
      ) do
        adapter.convert(input: input, output_dir: output_dir)
      end

      assert_includes adapter.command, "--no-ocr"
    end
  end

  private

  def with_adapter(extra_config = {})
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "page-14.pdf")
      output_dir = File.join(tmpdir, "output")

      File.write(input, "%PDF fake fixture")

      config = {
        "converter" => {
          "executable" => "docling",
          "command" => '%{executable} "%{input}" --to md --output "%{output_dir}" --image-export-mode placeholder --no-ocr',
          "timeout_seconds" => 600
        }.merge(extra_config)
      }

      adapter = RecordingAdapter.new(config: config)
      yield adapter, input, output_dir
    end
  end
end
