# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/page_marker"

class PageMarkerTest < Minitest::Test
  def test_renders_expected_marker
    assert_equal "<!-- PDF Page 12 -->", PdfToLlmMd::PageMarker.render(12)
  end

  def test_rejects_non_positive_page
    assert_raises(ArgumentError) { PdfToLlmMd::PageMarker.render(0) }
  end
end
