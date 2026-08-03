# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/assembler"

class AssemblerTest < Minitest::Test
  def setup
    @config = YAML.safe_load_file(File.expand_path("../config/conversion.yml", __dir__))
  end

  def test_orders_pages_and_adds_markers
    output = PdfToLlmMd::Assembler.new(config: @config).assemble(
      page_documents: { 2 => "Second", 1 => "First" },
      metadata: { title: "Test", source_pdf: "test.pdf", page_count: 2, page_range: "PDF pages 1–2" }
    )

    assert_operator output.index("<!-- PDF Page 1 -->"), :<, output.index("<!-- PDF Page 2 -->")
    assert_includes output, "title: Test"
  end
end
