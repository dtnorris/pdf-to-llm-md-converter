# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/auto_adapter"

class AutoAdapterTest < Minitest::Test
  SourceResult = PdfToLlmMd::SourcePageInspector::Result

  class FakeInspector
    def initialize(result)
      @result = result
    end

    def inspect(input:)
      @result
    end
  end

  class FakeAdapter
    attr_reader :calls

    def initialize(markdown:, available: true, diagnostics: nil)
      @markdown = markdown
      @available = available
      @diagnostics = diagnostics
      @calls = 0
    end

    def available?
      @available
    end

    def convert(input:, output_dir:)
      @calls += 1
      FileUtils.mkdir_p(output_dir)
      if @diagnostics
        File.write(
          File.join(output_dir, "page.vision-order.json"),
          JSON.generate(@diagnostics)
        )
      end
      @markdown
    end
  end

  def test_text_native_page_stays_on_docling
    docling = FakeAdapter.new(markdown: "docling native text")
    vision = FakeAdapter.new(markdown: "vision", diagnostics: vision_diagnostics)
    adapter = build_adapter(
      source(characters: 500, words: 80, fonts: 4),
      docling: docling,
      vision: vision
    )

    with_paths do |input, output_dir|
      result = adapter.convert_with_metadata(input: input, output_dir: output_dir)

      assert_equal "docling", result.backend
      assert_equal "native_text", result.diagnostics.fetch("selection_reason")
      assert_equal 1, docling.calls
      assert_equal 0, vision.calls
    end
  end

  def test_scanned_page_uses_vision
    docling = FakeAdapter.new(markdown: "docling")
    vision = FakeAdapter.new(markdown: "vision adventure text " * 20, diagnostics: vision_diagnostics)
    adapter = build_adapter(
      source(characters: 0, words: 0, fonts: 0),
      docling: docling,
      vision: vision
    )

    with_paths do |input, output_dir|
      result = adapter.convert_with_metadata(input: input, output_dir: output_dir)

      assert_equal "apple-vision", result.backend
      assert_equal "image_only_or_scanned", result.diagnostics.fetch("selection_reason")
      assert_equal 0, docling.calls
      assert_equal 1, vision.calls
    end
  end

  def test_scanned_page_fails_closed_when_vision_is_unavailable
    adapter = build_adapter(
      source(characters: 0, words: 0, fonts: 0),
      docling: FakeAdapter.new(markdown: "docling"),
      vision: FakeAdapter.new(markdown: "vision", available: false)
    )

    with_paths do |input, output_dir|
      error = assert_raises(PdfToLlmMd::AdapterError) do
        adapter.convert_with_metadata(input: input, output_dir: output_dir)
      end

      assert_includes error.message, "image-only/scanned"
      assert_includes error.message, "Apple Vision is unavailable"
    end
  end

  def test_table_like_vision_page_falls_back_to_structured_docling_output
    table = "| CR | AC | HP | Attack |\n|---|---|---|---|\n" + ("| 5 | 16 | 80 | claw |\n" * 20)
    docling = FakeAdapter.new(markdown: table)
    vision = FakeAdapter.new(
      markdown: "flattened vision text " * 20,
      diagnostics: vision_diagnostics.merge("table_like" => true, "recognized_characters" => 220)
    )
    adapter = build_adapter(
      source(characters: 0, words: 0, fonts: 0),
      docling: docling,
      vision: vision
    )

    with_paths do |input, output_dir|
      result = adapter.convert_with_metadata(input: input, output_dir: output_dir)

      assert_equal "docling", result.backend
      assert result.diagnostics.fetch("table_fallback_safe")
      assert_equal "vision_table_like_docling_fallback", result.diagnostics.fetch("selection_reason")
    end
  end

  def test_table_like_page_remains_review_required_when_docling_has_no_table_structure
    docling = FakeAdapter.new(markdown: "plain flattened fallback " * 30)
    vision = FakeAdapter.new(
      markdown: "flattened vision text " * 20,
      diagnostics: vision_diagnostics.merge("table_like" => true)
    )
    adapter = build_adapter(
      source(characters: 0, words: 0, fonts: 0),
      docling: docling,
      vision: vision
    )

    with_paths do |input, output_dir|
      result = adapter.convert_with_metadata(input: input, output_dir: output_dir)

      assert_equal "apple-vision", result.backend
      refute result.diagnostics.fetch("table_fallback_safe")
      assert_equal "vision_table_like_review_required", result.diagnostics.fetch("selection_reason")
    end
  end

  private

  def build_adapter(source_result, docling:, vision:)
    PdfToLlmMd::AutoAdapter.new(
      config: {},
      inspector: FakeInspector.new(source_result),
      docling_adapter: docling,
      vision_adapter: vision
    )
  end

  def source(characters:, words:, fonts:)
    SourceResult.new(
      text_available: true,
      native_text_characters: characters,
      native_text_words: words,
      font_count: fonts
    )
  end

  def vision_diagnostics
    {
      "table_like" => false,
      "recognized_characters" => 300,
      "kept_characters" => 290,
      "columns" => 2
    }
  end

  def with_paths
    Dir.mktmpdir do |tmpdir|
      input = File.join(tmpdir, "page.pdf")
      output_dir = File.join(tmpdir, "out")
      File.write(input, "%PDF fake")
      yield input, output_dir
    end
  end
end
