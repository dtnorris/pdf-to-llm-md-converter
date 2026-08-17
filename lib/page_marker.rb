# frozen_string_literal: true

module PdfToLlmMd
  class PageMarker
    TEMPLATE = "<!-- PDF Page %<page>d -->"
    PRINTED_PAGE_TEMPLATE = "<!-- Printed Page %<page>d -->"
    PAGE_LABEL_TEMPLATE = "<!-- PDF Page Label %<label>s -->"

    def self.render(page, page_label: nil)
      raise ArgumentError, "page must be a positive integer" unless page.is_a?(Integer) && page.positive?

      markers = [format(TEMPLATE, page: page)]
      label = normalize_page_label(page_label)
      return markers.first unless label

      if label.match?(/\A[1-9]\d*\z/)
        markers << format(PRINTED_PAGE_TEMPLATE, page: Integer(label, 10))
      else
        markers << format(PAGE_LABEL_TEMPLATE, label: label)
      end

      markers.join("\n")
    end

    def self.normalize_page_label(page_label)
      return nil if page_label.nil?

      label = page_label.to_s.strip.gsub(/[\r\n]+/, " ")
      return nil if label.empty?

      label.gsub("--", "—")
    end
    private_class_method :normalize_page_label
  end
end
