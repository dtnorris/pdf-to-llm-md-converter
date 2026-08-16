# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
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
            FakeStatus.new(false, 2)
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
        assert_includes error.message, "qpdf exit status: 2"
        assert_includes error.message, "checking malformed page"
        assert_includes error.message, "unable to find /Root dictionary"
      end
    end
  end

  def test_validate_extracted_page_accepts_qpdf_warnings
    Dir.mktmpdir do |tmpdir|
      converter = build_converter(tmpdir)

      Open3.stub(
        :capture3,
        [
          "checking page.pdf",
          "qpdf: operation succeeded with warnings",
          FakeStatus.new(false, 3)
        ]
      ) do
        result = converter.send(
          :validate_extracted_page!,
          "/tmp/page-1.pdf",
          1
        )

        assert_nil result
      end
    end
  end

  def test_convert_passes_pdf_page_labels_into_assembled_markers
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "book.pdf")
      output_dir = File.join(tmpdir, "build")
      File.write(input, "%PDF fake fixture")
      adapter = Object.new
      adapter.define_singleton_method(:convert) { |input:, output_dir:| "Converted page" }
      converter = build_converter(tmpdir, adapter: adapter)

      capture3 = lambda do |*command|
        if command.first == "pdfinfo"
          ["Pages:          27\n", "", FakeStatus.new(true, 0)]
        elsif command[1] == "--check"
          ["checking extracted page", "", FakeStatus.new(true, 0)]
        else
          File.write(command.last, "%PDF extracted page")
          ["", "", FakeStatus.new(true, 0)]
        end
      end

      PdfToLlmMd::PageLabels.stub(:extract, { 27 => "24" }) do
        Open3.stub(:capture3, capture3) do
          result = converter.convert(
            input: input,
            output_dir: output_dir,
            from_page: 27,
            to_page: 27
          )

          markdown = File.read(result.output_path)
          assert_includes markdown, "<!-- PDF Page 27 -->\n<!-- Printed Page 24 -->"
        end
      end
    end
  end

  private

  def build_converter(tmpdir, adapter: nil)
    config_path = File.join(tmpdir, "conversion.yml")
    File.write(config_path, {}.to_yaml)
    PdfToLlmMd::Converter.new(config_path: config_path, adapter: adapter)
  end
end
