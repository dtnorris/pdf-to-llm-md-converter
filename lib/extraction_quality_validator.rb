# frozen_string_literal: true

module PdfToLlmMd
  ExtractionQualityIssue = Data.define(:page, :backend, :reason, :diagnostics)
  ExtractionQualityResult = Data.define(:valid, :issues, :pages)

  class ExtractionQualityValidator
    DEFAULT_MINIMUM_REFERENCE_CHARACTERS = 120
    DEFAULT_MINIMUM_MISSING_CHARACTERS = 100
    DEFAULT_MINIMUM_COVERAGE_RATIO = 0.55

    def initialize(config:)
      @config = config
    end

    def validate(page_results:)
      issues = []
      summaries = {}

      page_results.each do |page, result|
        markdown = result.markdown.to_s
        diagnostics = stringify_keys(result.diagnostics || {})
        backend = result.backend.to_s
        extracted_characters = substantive_characters(markdown)

        summary = diagnostics.merge(
          "backend" => backend,
          "extracted_characters" => extracted_characters
        )
        summaries[page] = summary.freeze

        if backend == "apple-vision" && diagnostics.fetch("table_like", false)
          details = [
            "table_rows=#{diagnostics.fetch("table_rows", "unknown")}",
            "row_ratio=#{diagnostics.fetch("table_row_ratio", "unknown")}"
          ]
          if diagnostics.key?("docling_table_rows")
            details << "docling_table_rows=#{diagnostics.fetch("docling_table_rows")}"
            details << "docling_to_vision=#{diagnostics.fetch("docling_to_vision_character_ratio", "unknown")}"
          end

          issues << issue(
            page,
            backend,
            "table-like geometry is unsafe for prose-column Vision ordering (#{details.join(', ')})",
            summary
          )
        end

        source_characters = integer_or_nil(diagnostics["source_native_characters"])
        if source_characters
          add_coverage_issue(
            issues,
            page: page,
            backend: backend,
            reference_label: "native source text",
            reference_characters: source_characters,
            extracted_characters: extracted_characters,
            diagnostics: summary
          )
        end

        recognized_characters = integer_or_nil(diagnostics["recognized_characters"])
        if recognized_characters
          add_coverage_issue(
            issues,
            page: page,
            backend: backend,
            reference_label: "Vision recognized text",
            reference_characters: recognized_characters,
            extracted_characters: extracted_characters,
            diagnostics: summary
          )
        end
      end

      ExtractionQualityResult.new(
        valid: issues.empty?,
        issues: issues.freeze,
        pages: summaries.freeze
      )
    end

    private

    def add_coverage_issue(
      issues,
      page:,
      backend:,
      reference_label:,
      reference_characters:,
      extracted_characters:,
      diagnostics:
    )
      return if reference_characters < minimum_reference_characters

      missing = reference_characters - extracted_characters
      return if missing < minimum_missing_characters

      ratio = extracted_characters.fdiv(reference_characters)
      return if ratio >= minimum_coverage_ratio

      issues << issue(
        page,
        backend,
        format(
          "extracted text covers only %.1f%% of %s (%d vs %d characters)",
          ratio * 100,
          reference_label,
          extracted_characters,
          reference_characters
        ),
        diagnostics.merge(
          "quality_reference" => reference_label,
          "quality_coverage_ratio" => ratio.round(4),
          "quality_missing_characters" => missing
        )
      )
    end

    def issue(page, backend, reason, diagnostics)
      ExtractionQualityIssue.new(
        page: page,
        backend: backend,
        reason: reason,
        diagnostics: diagnostics.freeze
      )
    end

    def substantive_characters(markdown)
      markdown.gsub(/<!--.*?-->/m, "").scan(/[[:alnum:]]/).length
    end

    def stringify_keys(hash)
      hash.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value
      end
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def minimum_reference_characters
      config_integer("minimum_reference_characters", DEFAULT_MINIMUM_REFERENCE_CHARACTERS)
    end

    def minimum_missing_characters
      config_integer("minimum_missing_characters", DEFAULT_MINIMUM_MISSING_CHARACTERS)
    end

    def minimum_coverage_ratio
      config_float("minimum_coverage_ratio", DEFAULT_MINIMUM_COVERAGE_RATIO)
    end

    def config_integer(key, default)
      Integer(@config.dig("extraction_quality", key) || default)
    rescue ArgumentError, TypeError
      default
    end

    def config_float(key, default)
      Float(@config.dig("extraction_quality", key) || default)
    rescue ArgumentError, TypeError
      default
    end
  end
end
