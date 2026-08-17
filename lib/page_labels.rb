# frozen_string_literal: true

require "json"
require "open3"
require_relative "docling_adapter"

module PdfToLlmMd
  class PageLabels
    def self.extract(input:, pages:)
      new(input: input).labels_for(pages)
    end

    def initialize(input:)
      @input = File.expand_path(input)
    end

    def labels_for(pages)
      specs = load_specs
      return {}.freeze if specs.empty?

      Array(pages).each_with_object({}) do |page, labels|
        validate_page!(page)
        spec = specs.reverse_each.find { |candidate| candidate.fetch(:index) <= page - 1 }
        next unless spec

        label = render_label(spec, page - 1)
        labels[page] = label unless label.empty?
      end.freeze
    end

    private

    def load_specs
      stdout, stderr, status = Open3.capture3(
        "qpdf",
        "--json",
        "--json-key=pagelabels",
        @input
      )

      unless [0, 3].include?(status.exitstatus)
        raise AdapterError, <<~MESSAGE
          Unable to inspect PDF page labels
          Input: #{@input}
          qpdf exit status: #{status.exitstatus}

          STDERR:
          #{stderr}
        MESSAGE
      end

      data = JSON.parse(stdout)
      Array(data["pagelabels"]).map do |entry|
        index = Integer(entry.fetch("index"))
        label = entry.fetch("label")
        raise TypeError, "page label must be a dictionary" unless label.is_a?(Hash)

        { index: index, label: label.freeze }.freeze
      end.sort_by { |entry| entry.fetch(:index) }.freeze
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
      raise AdapterError, "Unable to parse qpdf page-label metadata for #{@input}: #{e.message}"
    rescue Errno::ENOENT => e
      raise AdapterError, "Unable to inspect PDF page labels: #{e.message}"
    end

    def render_label(spec, page_index)
      dictionary = spec.fetch(:label)
      prefix = decode_pdf_string(dictionary["/P"])
      style = decode_pdf_name(dictionary["/S"])
      return prefix unless style

      start = Integer(dictionary.fetch("/St", 1))
      value = start + page_index - spec.fetch(:index)
      raise ArgumentError, "page label value must be positive" unless value.positive?

      "#{prefix}#{format_value(value, style)}"
    end

    def format_value(value, style)
      case style
      when "D"
        value.to_s
      when "R"
        roman(value)
      when "r"
        roman(value).downcase
      when "A"
        alphabetic(value)
      when "a"
        alphabetic(value).downcase
      else
        raise ArgumentError, "unsupported PDF page-label style #{style.inspect}"
      end
    end

    def roman(value)
      numerals = [
        [1000, "M"], [900, "CM"], [500, "D"], [400, "CD"],
        [100, "C"], [90, "XC"], [50, "L"], [40, "XL"],
        [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]
      ]
      remaining = value
      numerals.each_with_object(String.new) do |(amount, text), result|
        count, remaining = remaining.divmod(amount)
        result << text * count
      end
    end

    def alphabetic(value)
      letter = ((value - 1) % 26 + "A".ord).chr
      letter * (((value - 1) / 26) + 1)
    end

    def decode_pdf_name(value)
      return nil if value.nil?

      value.to_s.sub(/\An:/, "").sub(%r{\A/}, "")
    end

    def decode_pdf_string(value)
      return "" if value.nil?

      text = value.to_s
      return text.delete_prefix("u:") if text.start_with?("u:")

      text
    end

    def validate_page!(page)
      return if page.is_a?(Integer) && page.positive?

      raise ArgumentError, "page must be a positive integer"
    end
  end
end
