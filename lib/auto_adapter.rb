# frozen_string_literal: true

require "json"
require "thread"
require_relative "apple_vision_adapter"
require_relative "docling_adapter"
require_relative "extraction_result"
require_relative "source_page_inspector"

module PdfToLlmMd
  class AutoAdapter
    DEFAULT_NATIVE_TEXT_CHARACTERS = 80
    DEFAULT_SPARSE_NATIVE_TEXT_CHARACTERS = 20
    DEFAULT_TABLE_FALLBACK_MIN_ROWS = 3
    DEFAULT_TABLE_FALLBACK_MIN_VISION_COVERAGE = 0.60

    def initialize(
      config:,
      docling_adapter: nil,
      vision_adapter: nil,
      inspector: nil
    )
      @config = config
      @docling_adapter = docling_adapter || DoclingAdapter.new(config: config)
      @vision_adapter = vision_adapter || AppleVisionAdapter.new(config: config)
      @inspector = inspector || SourcePageInspector.new
      @vision_mutex = Mutex.new
    end

    def convert(input:, output_dir:)
      convert_with_metadata(input: input, output_dir: output_dir).markdown
    end

    def convert_with_metadata(input:, output_dir:)
      source = @inspector.inspect(input: input)
      unless source.text_available
        raise AdapterError,
              "Automatic backend selection requires pdftotext to inspect the isolated source page"
      end

      return docling_result(input, output_dir, source, "native_text") if text_native?(source)

      unless @vision_adapter.available?
        raise AdapterError, <<~MESSAGE.strip
          Automatic backend selection classified this page as image-only/scanned, but Apple Vision is unavailable.
          Required for scanned auto mode: macOS, xcrun, and pdftoppm.
          Native text characters: #{source.native_text_characters}; PDF fonts: #{source.font_count}.
          Re-run with --backend docling only if you intentionally accept the weaker OCR/layout path.
        MESSAGE
      end

      vision_markdown, vision_diagnostics = @vision_mutex.synchronize do
        markdown = @vision_adapter.convert(input: input, output_dir: output_dir)
        [markdown, load_vision_diagnostics(output_dir)]
      end

      diagnostics = source_diagnostics(source).merge(vision_diagnostics).merge(
        "selection_reason" => "image_only_or_scanned"
      )

      unless diagnostics.fetch("table_like", false)
        return ExtractionResult.new(
          markdown: vision_markdown,
          backend: "apple-vision",
          diagnostics: diagnostics.freeze
        )
      end

      fallback_output_dir = File.join(output_dir, "docling-fallback")
      docling_markdown = @docling_adapter.convert(
        input: input,
        output_dir: fallback_output_dir
      )
      table_rows = markdown_table_rows(docling_markdown)
      vision_characters = Integer(diagnostics.fetch("recognized_characters", 0))
      docling_characters = substantive_characters(docling_markdown)
      coverage = vision_characters.zero? ? 1.0 : docling_characters.fdiv(vision_characters)
      safe_fallback = table_rows >= table_fallback_min_rows &&
        coverage >= table_fallback_min_vision_coverage

      fallback_diagnostics = diagnostics.merge(
        "vision_table_like" => true,
        "docling_table_rows" => table_rows,
        "docling_characters" => docling_characters,
        "docling_to_vision_character_ratio" => coverage.round(4),
        "table_fallback_safe" => safe_fallback
      )

      if safe_fallback
        ExtractionResult.new(
          markdown: docling_markdown,
          backend: "docling",
          diagnostics: fallback_diagnostics.merge(
            "selection_reason" => "vision_table_like_docling_fallback"
          ).freeze
        )
      else
        ExtractionResult.new(
          markdown: vision_markdown,
          backend: "apple-vision",
          diagnostics: fallback_diagnostics.merge(
            "selection_reason" => "vision_table_like_review_required"
          ).freeze
        )
      end
    end

    private

    def text_native?(source)
      characters = source.native_text_characters
      return true if characters >= native_text_characters

      characters >= sparse_native_text_characters && source.font_count.positive?
    end

    def docling_result(input, output_dir, source, reason)
      ExtractionResult.new(
        markdown: @docling_adapter.convert(input: input, output_dir: output_dir),
        backend: "docling",
        diagnostics: source_diagnostics(source).merge(
          "selection_reason" => reason
        ).freeze
      )
    end

    def load_vision_diagnostics(output_dir)
      path = Dir.glob(File.join(output_dir, "*.vision-order.json")).max_by do |candidate|
        File.mtime(candidate)
      end
      raise AdapterError, "Apple Vision produced no ordering diagnostics in #{output_dir}" unless path

      JSON.parse(File.read(path, encoding: "UTF-8"))
    rescue JSON::ParserError => error
      raise AdapterError, "Invalid Apple Vision ordering diagnostics: #{error.message}"
    end

    def source_diagnostics(source)
      {
        "source_native_characters" => source.native_text_characters,
        "source_native_words" => source.native_text_words,
        "source_font_count" => source.font_count
      }
    end

    def markdown_table_rows(markdown)
      pipe_rows = markdown.lines.count { |line| line.count("|") >= 2 }
      html_rows = markdown.scan(/<tr\b/i).length
      [pipe_rows, html_rows].max
    end

    def substantive_characters(markdown)
      markdown.to_s.gsub(/<!--.*?-->/m, "").scan(/[[:alnum:]]/).length
    end

    def native_text_characters
      config_integer("native_text_characters", DEFAULT_NATIVE_TEXT_CHARACTERS)
    end

    def sparse_native_text_characters
      config_integer(
        "sparse_native_text_characters",
        DEFAULT_SPARSE_NATIVE_TEXT_CHARACTERS
      )
    end

    def table_fallback_min_rows
      config_integer("table_fallback_min_rows", DEFAULT_TABLE_FALLBACK_MIN_ROWS)
    end

    def table_fallback_min_vision_coverage
      config_float(
        "table_fallback_min_vision_coverage",
        DEFAULT_TABLE_FALLBACK_MIN_VISION_COVERAGE
      )
    end

    def config_integer(key, default)
      Integer(@config.dig("auto_backend", key) || default)
    rescue ArgumentError, TypeError
      default
    end

    def config_float(key, default)
      Float(@config.dig("auto_backend", key) || default)
    rescue ArgumentError, TypeError
      default
    end
  end
end
