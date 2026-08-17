# frozen_string_literal: true

require "open3"
require "rexml/document"
require "rexml/xpath"

module PdfToLlmMd
  class VisiblePageNumbers
    HEADER_FOOTER_BAND_RATIO = 0.12
    OUTER_EDGE_RATIO = 0.30
    CENTER_HALF_WIDTH_RATIO = 0.06
    MAX_DIGITS = 4

    def self.extract(input:, pages:, total_pages:)
      new(input: input, total_pages: total_pages).numbers_for(pages)
    end

    def initialize(input:, total_pages:)
      @input = File.expand_path(input)
      @total_pages = Integer(total_pages)
      raise ArgumentError, "total_pages must be positive" unless @total_pages.positive?
    end

    def numbers_for(pages)
      requested_pages = Array(pages).map { |page| validate_page!(page) }.uniq.sort
      return {}.freeze if requested_pages.empty?

      inspection_start = [requested_pages.first - 1, 1].max
      inspection_end = [requested_pages.last + 1, @total_pages].min
      page_nodes = load_page_nodes(inspection_start, inspection_end)
      return {}.freeze unless page_nodes

      expected_count = inspection_end - inspection_start + 1
      return {}.freeze unless page_nodes.length == expected_count

      candidates = page_nodes.each_with_index.each_with_object({}) do |(page_node, index), result|
        physical_page = inspection_start + index
        result[physical_page] = candidates_for(page_node)
      end

      requested_pages.each_with_object({}) do |physical_page, labels|
        supported = candidates.fetch(physical_page, []).select do |candidate|
          sequence_supported?(physical_page, candidate, candidates)
        end
        next unless supported.one?

        labels[physical_page] = supported.first.to_s
      end.freeze
    end

    private

    def load_page_nodes(first_page, last_page)
      stdout, _stderr, status = Open3.capture3(
        "pdftotext",
        "-f", first_page.to_s,
        "-l", last_page.to_s,
        "-bbox-layout",
        "-cropbox",
        "-enc", "UTF-8",
        @input,
        "-"
      )
      return nil unless status.success?

      document = REXML::Document.new(stdout)
      REXML::XPath.match(document, "//*[local-name()='page']")
    rescue Errno::ENOENT, REXML::ParseException
      nil
    end

    def candidates_for(page_node)
      page_width = positive_float(page_node.attributes["width"])
      page_height = positive_float(page_node.attributes["height"])
      return [].freeze unless page_width && page_height

      REXML::XPath.match(page_node, ".//*[local-name()='line']").filter_map do |line|
        words = REXML::XPath.match(line, ".//*[local-name()='word']")
        next unless words.length == 1

        text = words.first.text.to_s.strip
        next unless text.match?(/\A[1-9]\d{0,#{MAX_DIGITS - 1}}\z/)

        value = Integer(text, 10)
        next if value > @total_pages
        next unless margin_line?(line, page_height)
        next unless plausible_horizontal_position?(line, page_width)

        value
      end.uniq.freeze
    end

    def margin_line?(line, page_height)
      y_min = float(line.attributes["yMin"])
      y_max = float(line.attributes["yMax"])
      return false unless y_min && y_max

      y_max <= page_height * HEADER_FOOTER_BAND_RATIO ||
        y_min >= page_height * (1.0 - HEADER_FOOTER_BAND_RATIO)
    end

    def plausible_horizontal_position?(line, page_width)
      x_min = float(line.attributes["xMin"])
      x_max = float(line.attributes["xMax"])
      return false unless x_min && x_max

      center = (x_min + x_max) / 2.0
      outer = center <= page_width * OUTER_EDGE_RATIO ||
        center >= page_width * (1.0 - OUTER_EDGE_RATIO)
      centered = (center - (page_width / 2.0)).abs <= page_width * CENTER_HALF_WIDTH_RATIO
      outer || centered
    end

    def sequence_supported?(physical_page, value, candidates)
      previous = candidates.fetch(physical_page - 1, [])
      following = candidates.fetch(physical_page + 1, [])

      previous.include?(value - 1) || following.include?(value + 1)
    end

    def positive_float(value)
      number = float(value)
      number if number&.positive?
    end

    def float(value)
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def validate_page!(page)
      unless page.is_a?(Integer) && page.positive? && page <= @total_pages
        raise ArgumentError, "page must be within 1–#{@total_pages}"
      end

      page
    end
  end
end
