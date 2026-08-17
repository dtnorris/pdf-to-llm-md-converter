# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/visible_page_numbers"

class VisiblePageNumbersTest < Minitest::Test
  FakeStatus = Struct.new(:success_value) do
    def success?
      success_value
    end
  end

  def test_detects_sequential_isolated_numbers_in_page_margins
    xhtml = document(
      page(lines: []),
      page(lines: [line("24", x: 20, y: 20)]),
      page(lines: [line("25", x: 570, y: 760)]),
      page(lines: [line("26", x: 300, y: 18)]),
      page(lines: [])
    )

    Open3.stub(:capture3, [xhtml, "", FakeStatus.new(true)]) do
      labels = PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27, 28, 29],
        total_pages: 290
      )

      assert_equal({ 27 => "24", 28 => "25", 29 => "26" }, labels)
    end
  end

  def test_inspects_neighbor_pages_to_confirm_a_single_requested_page
    xhtml = document(
      page(lines: [line("24", x: 20, y: 20)]),
      page(lines: [line("25", x: 570, y: 760)]),
      page(lines: [line("26", x: 20, y: 20)])
    )
    command = nil

    capture3 = lambda do |*args|
      command = args
      [xhtml, "", FakeStatus.new(true)]
    end

    Open3.stub(:capture3, capture3) do
      labels = PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [28],
        total_pages: 290
      )

      assert_equal({ 28 => "25" }, labels)
    end

    assert_equal [
      "pdftotext", "-f", "27", "-l", "29", "-bbox-layout", "-cropbox",
      "-enc", "UTF-8", "/tmp/book.pdf", "-"
    ], command
  end

  def test_rejects_body_numbers_multiword_lines_and_nonsequential_margin_numbers
    xhtml = document(
      page(lines: [
        line("24", x: 20, y: 300),
        line("2025", x: 20, y: 760),
        line("23", x: 20, y: 20, extra_word: "CHAPTER")
      ]),
      page(lines: [line("2025", x: 570, y: 760)]),
      page(lines: [line("2025", x: 20, y: 760)]),
      page(lines: [])
    )

    Open3.stub(:capture3, [xhtml, "", FakeStatus.new(true)]) do
      labels = PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [1, 2, 3],
        total_pages: 290
      )

      assert_equal({}, labels)
    end
  end

  def test_rejects_ambiguous_competing_sequences_on_the_same_page
    xhtml = document(
      page(lines: []),
      page(lines: [line("24", x: 20, y: 20), line("100", x: 300, y: 20)]),
      page(lines: [line("25", x: 570, y: 760), line("101", x: 300, y: 760)]),
      page(lines: [line("26", x: 20, y: 20), line("102", x: 300, y: 20)]),
      page(lines: [])
    )

    Open3.stub(:capture3, [xhtml, "", FakeStatus.new(true)]) do
      labels = PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27, 28, 29],
        total_pages: 290
      )

      assert_equal({}, labels)
    end
  end

  def test_returns_empty_mapping_when_pdftotext_fails_or_output_is_malformed
    Open3.stub(:capture3, ["", "broken pdf", FakeStatus.new(false)]) do
      assert_equal({}, PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf", pages: [1], total_pages: 10
      ))
    end

    Open3.stub(:capture3, ["<not-xml", "", FakeStatus.new(true)]) do
      assert_equal({}, PdfToLlmMd::VisiblePageNumbers.extract(
        input: "/tmp/book.pdf", pages: [1], total_pages: 10
      ))
    end
  end

  private

  def document(*pages)
    <<~XML
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml"><body><doc>
      #{pages.join("\n")}
      </doc></body></html>
    XML
  end

  def page(lines:)
    <<~XML
      <page width="612" height="792"><flow><block>
      #{lines.join("\n")}
      </block></flow></page>
    XML
  end

  def line(text, x:, y:, extra_word: nil)
    words = [word(text, x: x, y: y)]
    words << word(extra_word, x: x + 40, y: y) if extra_word
    <<~XML
      <line xMin="#{x}" yMin="#{y}" xMax="#{x + 30}" yMax="#{y + 12}">
        #{words.join("\n")}
      </line>
    XML
  end

  def word(text, x:, y:)
    %(<word xMin="#{x}" yMin="#{y}" xMax="#{x + 20}" yMax="#{y + 12}">#{text}</word>)
  end
end
