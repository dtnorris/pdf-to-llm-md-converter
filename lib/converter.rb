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

    def convert(
      input:,
      output_dir:,
      title: nil,
      from_page: 1,
      to_page: nil,
      progress: nil
    )
      input = File.expand_path(input)
      raise ArgumentError, "Input PDF not found: #{input}" unless File.file?(input)
      raise ArgumentError, "Input must be a PDF" unless File.extname(input).casecmp?(".pdf")

      total_pages = pdf_page_count(input)
      notify(progress, :inspect_pdf, total_pages: total_pages)
      to_page ||= total_pages
      validate_range!(from_page, to_page, total_pages)
      
      pages = (from_page..to_page).to_a
      
      notify(
        progress,
        :start_conversion,
        total_pages: pages.length
      )
      
      FileUtils.mkdir_p(output_dir)
      page_documents = extract_pages(
        input: input,
        pages: pages,
        progress: progress
      )
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
      validation = Validator.new(config: @config).validate(
        markdown: markdown,
        expected_pages: pages
      )
      
      notify(
        progress,
        :validation,
        result: validation
      )
      
      ConversionResult.new(
        output_path: output_path,
        validation: validation,
        pages: pages.freeze
      )
    end

    private

    def extract_pages(input:, pages:, progress: nil)
      Dir.mktmpdir("pdf-to-llm-md-") do |tmpdir|
        documents = {}
    
        pages.each_with_index do |page, index|
          page_pdf = extract_page(
            input: input,
            page: page,
            tmpdir: tmpdir
          )
    
          page_output = File.join(
            tmpdir,
            "docling-page-#{format('%04d', page)}"
          )
    
          documents[page] = @adapter.convert(
            input: page_pdf,
            output_dir: page_output
          )
    
          notify(
            progress,
            :advance,
            current: index + 1,
            total_pages: pages.length
          )
        end
    
        documents
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

    def notify(progress, event, **payload)
      return unless progress
    
      if progress.respond_to?(event)
        progress.public_send(event, **payload)
      elsif progress.respond_to?(:call)
        message = legacy_progress_message(event, payload)
        progress.call(message) if message
      end
    end
    
    def legacy_progress_message(event, payload)
      case event
      when :inspect_pdf
        "Inspecting PDF: #{payload.fetch(:total_pages)} pages"
      when :advance
        "Converted page #{payload.fetch(:current)} of #{payload.fetch(:total_pages)}"
      end
    end
  end
end
