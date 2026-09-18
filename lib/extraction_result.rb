# frozen_string_literal: true

module PdfToLlmMd
  ExtractionResult = Data.define(:markdown, :backend, :diagnostics)
end
