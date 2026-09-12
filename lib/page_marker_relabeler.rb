# frozen_string_literal: true

require "digest"
require "fileutils"

module PdfToLlmMd
  RelabelResult = Data.define(
    :input_path,
    :output_path,
    :pdf_pages,
    :printed_markers_before,
    :page_labels_before,
    :printed_markers_after,
    :offset,
    :input_sha256,
    :output_sha256,
    :content_sha256
  )

  # Rewrites only pagination annotations in an already-converted Markdown file.
  # It never invokes Docling or reads the source PDF.
  class PageMarkerRelabeler
    PDF_MARKER = /\A<!-- PDF Page (\d+) -->\r?\n?\z/
    PRINTED_MARKER = /\A<!-- Printed Page (\d+) -->\r?\n?\z/
    PAGE_LABEL_MARKER = /\A<!-- PDF Page Label (.*?) -->\r?\n?\z/

    def self.relabel!(input:, output:, offset:, expected_pages: nil)
      new(
        input: input,
        output: output,
        offset: offset,
        expected_pages: expected_pages
      ).relabel!
    end

    def initialize(input:, output:, offset:, expected_pages:)
      @input = File.expand_path(input.to_s)
      @output = File.expand_path(output.to_s)
      @offset = Integer(offset)
      @expected_pages = expected_pages.nil? ? nil : Integer(expected_pages)
    rescue ArgumentError, TypeError
      raise ArgumentError, "offset and expected page count must be integers"
    end

    def relabel!
      validate_paths!
      source = File.read(@input, encoding: "UTF-8")
      lines = source.lines
      pages = pdf_pages(lines)
      validate_pages!(pages)

      before_printed = lines.count { |line| PRINTED_MARKER.match?(line) }
      before_labels = lines.count { |line| PAGE_LABEL_MARKER.match?(line) }
      rewritten = rewrite(lines)

      unless content_without_page_labels(source) == content_without_page_labels(rewritten)
        raise "refusing relabel: non-pagination content changed"
      end

      FileUtils.mkdir_p(File.dirname(@output))
      File.open(@output, "wx:UTF-8") { |file| file.write(rewritten) }

      RelabelResult.new(
        input_path: @input,
        output_path: @output,
        pdf_pages: pages.length,
        printed_markers_before: before_printed,
        page_labels_before: before_labels,
        printed_markers_after: rewritten.scan(/<!-- Printed Page \d+ -->/).length,
        offset: @offset,
        input_sha256: sha256(@input),
        output_sha256: sha256(@output),
        content_sha256: Digest::SHA256.hexdigest(content_without_page_labels(source))
      )
    rescue Errno::EEXIST
      raise ArgumentError, "refusing to overwrite existing output: #{@output}"
    end

    private

    def validate_paths!
      raise ArgumentError, "input Markdown not found: #{@input}" unless File.file?(@input)
      raise ArgumentError, "input and output must be different paths" if @input == @output
      raise ArgumentError, "refusing to overwrite existing output: #{@output}" if File.exist?(@output)
      if @expected_pages && @expected_pages <= 0
        raise ArgumentError, "expected page count must be positive"
      end
    end

    def pdf_pages(lines)
      lines.filter_map do |line|
        match = PDF_MARKER.match(line)
        Integer(match[1], 10) if match
      end
    end

    def validate_pages!(pages)
      raise ArgumentError, "no PDF page markers found" if pages.empty?

      duplicates = pages.tally.select { |_page, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "duplicate PDF page markers: #{duplicates.join(', ')}"
      end

      bad_transition = pages.each_cons(2).find { |left, right| right != left + 1 }
      if bad_transition
        raise ArgumentError,
              "PDF page markers are not contiguous: #{bad_transition[0]} -> #{bad_transition[1]}"
      end

      if @expected_pages && pages.length != @expected_pages
        raise ArgumentError,
              "expected #{@expected_pages} PDF page markers, found #{pages.length}"
      end
    end

    def rewrite(lines)
      output = []
      index = 0

      while index < lines.length
        line = lines[index]
        match = PDF_MARKER.match(line)
        unless match
          output << line
          index += 1
          next
        end

        page = Integer(match[1], 10)
        output << line
        index += 1

        while index < lines.length && pagination_label_line?(lines[index])
          index += 1
        end

        printed_page = page + @offset
        output << "<!-- Printed Page #{printed_page} -->#{line_ending(line)}" if printed_page.positive?
      end

      output.join
    end

    def pagination_label_line?(line)
      PRINTED_MARKER.match?(line) || PAGE_LABEL_MARKER.match?(line)
    end

    def line_ending(line)
      line.end_with?("\r\n") ? "\r\n" : "\n"
    end

    def content_without_page_labels(markdown)
      markdown.lines.reject { |line| pagination_label_line?(line) }.join
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end
  end
end
