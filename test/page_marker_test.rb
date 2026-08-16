# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/page_marker"

class PageMarkerTest < Minitest::Test
  def test_renders_expected_marker
    assert_equal "<!-- PDF Page 12 -->", PdfToLlmMd::PageMarker.render(12)
  end

  def test_adds_printed_page_marker_for_numeric_pdf_page_label
    assert_equal(
      "<!-- PDF Page 27 -->\n<!-- Printed Page 24 -->",
      PdfToLlmMd::PageMarker.render(27, page_label: "24")
    )
  end

  def test_preserves_non_numeric_pdf_page_label_without_calling_it_a_printed_page
    assert_equal(
      "<!-- PDF Page 4 -->\n<!-- PDF Page Label iv -->",
      PdfToLlmMd::PageMarker.render(4, page_label: "iv")
    )
  end

  def test_sanitizes_page_labels_before_embedding_them_in_html_comments
    assert_equal(
      "<!-- PDF Page 3 -->\n<!-- PDF Page Label A—B C -->",
      PdfToLlmMd::PageMarker.render(3, page_label: "A--B\nC")
    )
  end

  def test_rejects_non_positive_page
    assert_raises(ArgumentError) { PdfToLlmMd::PageMarker.render(0) }
  end
end
