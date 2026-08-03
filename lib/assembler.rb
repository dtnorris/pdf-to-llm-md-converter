# frozen_string_literal: true

require "yaml"
require_relative "page_marker"

module PdfToLlmMd
  class Assembler
    def initialize(config:)
      @config = config
    end

    def assemble(page_documents:, metadata: {})
      sections = []
      sections << front_matter(metadata) if include_front_matter?

      page_documents.sort_by { |page, _| page }.each do |page, markdown|
        sections << PageMarker.render(page)
        sections << normalize(markdown)
      end

      sections.reject(&:empty?).join("\n\n").rstrip + "\n"
    end

    private

    def include_front_matter?
      @config.dig("output", "include_front_matter") == true
    end

    def front_matter(metadata)
      data = {
        "title" => metadata.fetch(:title),
        "source_pdf" => metadata.fetch(:source_pdf),
        "page_count" => metadata.fetch(:page_count),
        "page_range" => metadata.fetch(:page_range),
        "conversion" => @config.dig("output", "conversion_label")
      }
      "---\n#{data.to_yaml.sub(/\A---\s*\n/, "")}---"
    end

    def normalize(markdown)
      value = markdown.to_s
      value = value.gsub("\r\n", "\n").gsub("\r", "\n") if @config.dig("processing", "normalize_line_endings")
      value = value.gsub(/\n{4,}/, "\n\n\n") if @config.dig("processing", "collapse_excess_blank_lines")
      value.strip
    end
  end
end
