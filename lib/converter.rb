# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"
require "yaml"
require_relative "assembler"
require_relative "docling_adapter"
require_relative "validator"

module PdfToLlmMd
  ConversionResult = Data.define(:output_path, :validation, :pages)

  class Converter
    def initialize(config_path:, adapter: nil)
      @config = YAML.safe_load_file(config_path)
      @adapter = adapter || DoclingAdapter.new(config: @config)
    end

    def convert(input:, output_dir:, title: nil, from_page: 1, to_page: nil)
      input = File.expand_path(input)
      raise ArgumentError, "Input PDF not found: #{input}" unless File.file?(input)
      raise ArgumentError, "Input must be a PDF" unless File.extname(input).casecmp?(".pdf")

      total_pages = pdf_page_count(input)
      to_page ||= total_pages
      validate_range!(from_page, to_page, total_pages)
      pages = (from_page..to_page).to_a

      FileUtils.mkdir_p(output_dir)
      page_documents = extract_pages(input: input, pages: pages)
      markdown = Assembler.new(config: @config).assemble(
        page_documents: page_documents,
        metadata: {
          title: title || File.basename(input, ".pdf"),
          source_pdf: File.basename(input),
          page_count: total_pages,
          page_range: "PDF pages #{from_page}–#{to_page}"
        }
      )

      output_path = File.join(output_dir, output_filename(input))
      File.write(output_path, markdown, encoding: "UTF-8")
      validation = Validator.new(config: @config).validate(markdown: markdown, expected_pages: pages)
      ConversionResult.new(output_path: output_path, validation: validation, pages: pages.freeze)
    end

    private

    def extract_pages(input:, pages:)
      Dir.mktmpdir("pdf-to-llm-md-") do |tmpdir|
        pages.to_h do |page|
          page_pdf = extract_page(input: input, page: page, tmpdir: tmpdir)
          page_output = File.join(tmpdir, "docling-page-#{format('%04d', page)}")
          [page, @adapter.convert(input: page_pdf, output_dir: page_output)]
        end
      end
    end

    def extract_page(input:, page:, tmpdir:)
      output_pattern = File.join(tmpdir, "page-%d.pdf")
      template = @config.dig("processing", "page_separator_command").to_s
      command = format(
        template,
        page: page,
        input: File.expand_path(input),
        output_pattern: output_pattern
      )
      stdout, stderr, status = Open3.capture3(command)
      raise AdapterError, "Page extraction failed for page #{page}: #{stderr}\n#{stdout}" unless status.success?

      path = format(output_pattern, page)
      raise AdapterError, "Page extractor did not create #{path}" unless File.file?(path)

      path
    end

    def pdf_page_count(input)
      stdout, stderr, status = Open3.capture3("pdfinfo", input)
      raise AdapterError, "pdfinfo failed: #{stderr}" unless status.success?

      match = stdout.match(/^Pages:\s+(\d+)$/)
      raise AdapterError, "Unable to determine PDF page count" unless match

      match[1].to_i
    end

    def validate_range!(from_page, to_page, total_pages)
      valid = from_page.positive? && to_page >= from_page && to_page <= total_pages
      raise ArgumentError, "Page range must be within 1–#{total_pages}" unless valid
    end

    def output_filename(input)
      suffix = @config.dig("output", "filename_suffix").to_s
      "#{File.basename(input, '.pdf').tr(' ', '_')}#{suffix}"
    end
  end
end
