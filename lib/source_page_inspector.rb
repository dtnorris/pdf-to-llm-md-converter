# frozen_string_literal: true

require "open3"

module PdfToLlmMd
  class SourcePageInspector
    Result = Data.define(
      :text_available,
      :native_text_characters,
      :native_text_words,
      :font_count
    )

    def inspect(input:)
      text, _stderr, status = Open3.capture3(
        "pdftotext",
        "-layout",
        File.expand_path(input),
        "-"
      )

      return failed_result unless status.success?

      Result.new(
        text_available: true,
        native_text_characters: substantive_characters(text),
        native_text_words: text.scan(/[[:alnum:]]+/).length,
        font_count: inspect_font_count(input)
      )
    rescue Errno::ENOENT
      failed_result
    end

    private

    def inspect_font_count(input)
      stdout, _stderr, status = Open3.capture3("pdffonts", File.expand_path(input))
      return 0 unless status.success?

      separator = stdout.lines.index { |line| line.match?(/^-{3,}/) }
      return 0 unless separator

      stdout.lines.drop(separator + 1).count { |line| !line.strip.empty? }
    rescue Errno::ENOENT
      0
    end

    def substantive_characters(text)
      text.to_s.scan(/[[:alnum:]]/).length
    end

    def failed_result
      Result.new(
        text_available: false,
        native_text_characters: 0,
        native_text_words: 0,
        font_count: 0
      )
    end
  end
end
