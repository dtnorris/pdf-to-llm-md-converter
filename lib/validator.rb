# frozen_string_literal: true

require_relative "page_marker"

module PdfToLlmMd
  ValidationResult = Data.define(:valid, :errors, :warnings, :stats)

  class Validator
    MARKER_PATTERN = /<!-- PDF Page (\d+) -->/

    def initialize(config:)
      @config = config
    end

    def validate(markdown:, expected_pages:)
      errors = []
      warnings = []
      markers = markdown.scan(MARKER_PATTERN).flatten.map(&:to_i)

      if require_page_markers?
        missing = expected_pages - markers
        duplicates = markers.tally.select { |_page, count| count > 1 }.keys
        errors << "Missing page markers: #{missing.join(', ')}" unless missing.empty?
        errors << "Duplicate page markers: #{duplicates.join(', ')}" unless duplicates.empty?
      end

      page_bodies = split_pages(markdown)
      minimum = @config.dig("validation", "minimum_characters_per_page").to_i
      short_pages = expected_pages.select { |page| page_bodies.fetch(page, "").strip.length < minimum }
      warnings << "Pages below #{minimum} characters: #{short_pages.join(', ')}" unless short_pages.empty?

      flagged_pages = []

      flag_patterns.each do |pattern|
        regexp = Regexp.new(pattern)
        matching_pages = expected_pages.select do |page|
          page_bodies.fetch(page, "").match?(regexp)
        end

        next if matching_pages.empty?

        flagged_pages.concat(matching_pages)
        warnings << "Flagged pattern found on pages #{matching_pages.join(', ')}: #{pattern.inspect}"
      rescue RegexpError
        warnings << "Invalid validation pattern in configuration: #{pattern.inspect}"
      end

      blank_ratio = expected_pages.empty? ? 0.0 : short_pages.length.fdiv(expected_pages.length)
      maximum_blank_ratio = @config.dig("validation", "maximum_blank_page_ratio").to_f
      errors << format("Blank/short page ratio %.2f exceeds %.2f", blank_ratio, maximum_blank_ratio) if blank_ratio > maximum_blank_ratio

      ValidationResult.new(
        valid: errors.empty?,
        errors: errors.freeze,
        warnings: warnings.freeze,
        stats: {
          expected_pages: expected_pages.length,
          page_markers: markers.length,
          missing_pages: missing.freeze,
          duplicate_pages: duplicates.freeze,
          short_pages: short_pages.length,
          flagged_pages: flagged_pages.uniq.sort.freeze,
          characters: markdown.length
        }.freeze
      )
    end

    private

    def require_page_markers?
      @config.dig("validation", "require_page_markers") == true
    end

    def flag_patterns
      Array(@config.dig("validation", "flag_patterns"))
    end

    def split_pages(markdown)
      parts = markdown.split(MARKER_PATTERN)
      result = {}
      parts.drop(1).each_slice(2) { |page, body| result[page.to_i] = body.to_s }
      result
    end
  end
end
