# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter"

class ConverterQpdfExtractionTest < Minitest::Test
  FakeStatus = Struct.new(:success_value, :exitstatus) do
    def success?
      success_value
    end
  end

  def test_extract_page_uses_qpdf_and_validates_the_created_pdf
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      File.write(input, "%PDF fake fixture")
      converter = build_converter(tmpdir)
      commands = []

      capture3 = lambda do |*command|
        commands << command

        if command[1] == "--check"
          ["checking extracted page", "", FakeStatus.new(true, 0)]
        else
          File.write(command.last, "%PDF extracted page")
          ["", "", FakeStatus.new(true, 0)]
        end
      end

      Open3.stub(:capture3, capture3) do
        result = converter.send(
          :extract_page,
          input: input,
          page: 6,
          tmpdir: tmpdir
        )

        expected_path = File.join(tmpdir, "page-6.pdf")
        assert_equal expected_path, result
        assert File.file?(expected_path)
      end

      assert_equal(
        [
          "qpdf",
          File.expand_path(input),
          "--pages",
          ".",
          "6",
          "--",
          File.join(tmpdir, "page-6.pdf")
        ],
        commands[0]
      )
      assert_equal(
        ["qpdf", "--check", File.join(tmpdir, "page-6.pdf")],
        commands[1]
      )
    end
  end

  def test_extract_page_reports_qpdf_extraction_failure
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      File.write(input, "%PDF fake fixture")
      converter = build_converter(tmpdir)

      Open3.stub(
        :capture3,
        ["extractor output", "unable to extract page", FakeStatus.new(false, 2)]
      ) do
        error = assert_raises(PdfToLlmMd::AdapterError) do
          converter.send(
            :extract_page,
            input: input,
            page: 6,
            tmpdir: tmpdir
          )
        end

        assert_includes error.message, "Page extraction failed for page 6"
        assert_includes error.message, "Exit status: 2"
        assert_includes error.message, "extractor output"
        assert_includes error.message, "unable to extract page"
      end
    end
  end

  def test_extract_page_rejects_an_invalid_extracted_pdf
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      File.write(input, "%PDF fake fixture")
      converter = build_converter(tmpdir)
      invocation = 0

      capture3 = lambda do |*command|
        invocation += 1

        if invocation == 1
          File.write(command.last, "%PDF malformed extracted page")
          ["", "", FakeStatus.new(true, 0)]
        else
          [
            "checking malformed page",
            "unable to find /Root dictionary",
            FakeStatus.new(false, 3)
          ]
        end
      end

      Open3.stub(:capture3, capture3) do
        error = assert_raises(PdfToLlmMd::AdapterError) do
          converter.send(
            :extract_page,
            input: input,
            page: 6,
            tmpdir: tmpdir
          )
        end

        assert_includes error.message, "Extracted PDF for page 6 is invalid"
        assert_includes error.message, "qpdf exit status: 3"
        assert_includes error.message, "checking malformed page"
        assert_includes error.message, "unable to find /Root dictionary"
      end
    end
  end

  private

  def build_converter(tmpdir)
    config_path = File.join(tmpdir, "conversion.yml")
    File.write(config_path, {}.to_yaml)
    PdfToLlmMd::Converter.new(config_path: config_path)
  end
end
