# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/source_page_inspector"

class SourcePageInspectorTest < Minitest::Test
  FakeStatus = Struct.new(:success_value) do
    def success?
      success_value
    end
  end

  def test_measures_native_text_and_pdf_fonts
    capture = lambda do |*command|
      case command.first
      when "pdftotext"
        ["Alpha beta 123\n", "", FakeStatus.new(true)]
      when "pdffonts"
        [
          "name type emb\n------------------\nHelvetica Type1 yes\nTimes Type1 yes\n",
          "",
          FakeStatus.new(true)
        ]
      else
        raise "unexpected command #{command.inspect}"
      end
    end

    Open3.stub(:capture3, capture) do
      result = PdfToLlmMd::SourcePageInspector.new.inspect(input: "/tmp/page.pdf")

      assert result.text_available
      assert_equal 12, result.native_text_characters
      assert_equal 3, result.native_text_words
      assert_equal 2, result.font_count
    end
  end

  def test_failed_pdftotext_is_not_treated_as_a_scanned_measurement
    Open3.stub(:capture3, ["", "failed", FakeStatus.new(false)]) do
      result = PdfToLlmMd::SourcePageInspector.new.inspect(input: "/tmp/page.pdf")

      refute result.text_available
      assert_equal 0, result.native_text_characters
      assert_equal 0, result.font_count
    end
  end
end
