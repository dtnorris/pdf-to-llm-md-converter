# frozen_string_literal: true

module PdfToLlmMd
  class PageMarker
    TEMPLATE = "<!-- PDF Page %<page>d -->"

    def self.render(page)
      raise ArgumentError, "page must be a positive integer" unless page.is_a?(Integer) && page.positive?

      format(TEMPLATE, page: page)
    end
  end
end
