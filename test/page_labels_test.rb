# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/page_labels"

class PageLabelsTest < Minitest::Test
  FakeStatus = Struct.new(:exitstatus)

  def test_expands_qpdf_page_label_ranges_for_requested_physical_pages
    payload = {
      "pagelabels" => [
        { "index" => 0, "label" => { "/S" => "/r" } },
        { "index" => 4, "label" => { "/S" => "/D" } },
        { "index" => 10, "label" => { "/S" => "/D", "/St" => 20, "/P" => "u:A-" } }
      ]
    }

    Open3.stub(:capture3, [JSON.generate(payload), "", FakeStatus.new(0)]) do
      labels = PdfToLlmMd::PageLabels.extract(
        input: "/tmp/book.pdf",
        pages: [1, 4, 5, 6, 11, 12]
      )

      assert_equal(
        { 1 => "i", 4 => "iv", 5 => "1", 6 => "2", 11 => "A-20", 12 => "A-21" },
        labels
      )
    end
  end

  def test_supports_pdf_alphabetic_page_labels
    payload = {
      "pagelabels" => [
        { "index" => 0, "label" => { "/S" => "/A" } }
      ]
    }

    Open3.stub(:capture3, [JSON.generate(payload), "", FakeStatus.new(0)]) do
      labels = PdfToLlmMd::PageLabels.extract(
        input: "/tmp/book.pdf",
        pages: [1, 26, 27, 52, 53]
      )

      assert_equal(
        { 1 => "A", 26 => "Z", 27 => "AA", 52 => "ZZ", 53 => "AAA" },
        labels
      )
    end
  end

  def test_returns_empty_mapping_when_pdf_has_no_explicit_page_labels
    payload = { "pagelabels" => [] }

    Open3.stub(:capture3, [JSON.generate(payload), "", FakeStatus.new(0)]) do
      labels = PdfToLlmMd::PageLabels.extract(
        input: "/tmp/book.pdf",
        pages: [1, 2, 3]
      )

      assert_equal({}, labels)
    end
  end

  def test_accepts_qpdf_warning_exit_status_when_json_is_available
    payload = {
      "pagelabels" => [
        { "index" => 0, "label" => { "/S" => "/D", "/St" => 24 } }
      ]
    }

    Open3.stub(:capture3, [JSON.generate(payload), "warning", FakeStatus.new(3)]) do
      labels = PdfToLlmMd::PageLabels.extract(input: "/tmp/book.pdf", pages: [1])

      assert_equal({ 1 => "24" }, labels)
    end
  end

  def test_reports_qpdf_page_label_inspection_failure
    Open3.stub(:capture3, ["", "broken pdf", FakeStatus.new(2)]) do
      error = assert_raises(PdfToLlmMd::AdapterError) do
        PdfToLlmMd::PageLabels.extract(input: "/tmp/book.pdf", pages: [1])
      end

      assert_includes error.message, "Unable to inspect PDF page labels"
      assert_includes error.message, "qpdf exit status: 2"
      assert_includes error.message, "broken pdf"
    end
  end
end
