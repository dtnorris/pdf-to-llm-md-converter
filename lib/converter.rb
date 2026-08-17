# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"
require "yaml"
require_relative "assembler"
require_relative "docling_adapter"
require_relative "page_labels"
require_relative "page_number_sequence"
require_relative "visible_page_numbers"
require_relative "visual_page_numbers"
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
      resolved_title = resolve_title(input, title)
      
      pages = (from_page..to_page).to_a
      page_labels = pdf_page_labels(input, pages)
      missing_page_labels = pages.reject { |page| page_labels.key?(page) }
      unless missing_page_labels.empty?
        visible_page_numbers = pdf_visible_page_numbers(
          input,
          missing_page_labels,
          total_pages
        )
        page_labels = visible_page_numbers.merge(page_labels).freeze
      end

      missing_page_labels = pages.reject { |page| page_labels.key?(page) }
      unless missing_page_labels.empty?
        visual_page_numbers = pdf_visual_page_numbers(
          input,
          missing_page_labels,
          total_pages,
          page_labels,
          progress
        )
        page_labels = visual_page_numbers.merge(page_labels).freeze
      end

      missing_page_labels = pages.reject { |page| page_labels.key?(page) }
      unless missing_page_labels.empty?
        inferred_page_numbers = pdf_inferred_page_numbers(
          pages,
          total_pages,
          page_labels
        )
        page_labels = inferred_page_numbers.merge(page_labels).freeze
      end
      
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
        page_labels: page_labels,
        metadata: {
          title: resolved_title,
          source_pdf: File.basename(input),
          page_count: total_pages,
          page_range: "PDF pages #{from_page}–#{to_page}"
        }
      )

      output_path = File.join(output_dir, output_filename(resolved_title))
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
        worker_count = Integer(
          @config.dig("processing", "parallel_workers") || 4
        ).clamp(1, 8)

        worker_count = 1 if worker_count < 1
        worker_count = 8 if worker_count > 8

        queue = Queue.new
        pages.each { |page| queue << page }
    
        documents = {}
        completed = 0
        mutex = Mutex.new
    
        workers = worker_count.times.map do
          Thread.new do
            loop do
              page = queue.pop(true)
    
              page_pdf = extract_page(
                input: input,
                page: page,
                tmpdir: tmpdir
              )
    
              page_output = File.join(
                tmpdir,
                "docling-page-#{format('%04d', page)}"
              )
    
              markdown = @adapter.convert(
                input: page_pdf,
                output_dir: page_output
              )
    
              mutex.synchronize do
                documents[page] = markdown
                completed += 1
    
                notify(
                  progress,
                  :advance,
                  current: completed,
                  total_pages: pages.length
                )
              end
            rescue ThreadError
              break
            end
          end
        end
    
        workers.each(&:join)
        documents
      end
    end

    def extract_page(input:, page:, tmpdir:)
      path = File.join(tmpdir, "page-#{page}.pdf")

      command = [
        "qpdf",
        File.expand_path(input),
        "--pages",
        ".",
        page.to_s,
        "--",
        path
      ]

      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        raise AdapterError, <<~MESSAGE
          Page extraction failed for page #{page}
          Command: #{command.inspect}
          Exit status: #{status.exitstatus}

          STDOUT:
          #{stdout}

          STDERR:
          #{stderr}
        MESSAGE
      end

      raise AdapterError, "Page extractor did not create #{path}" unless File.file?(path)

      validate_extracted_page!(path, page)

      path
    end

    def validate_extracted_page!(path, page)
      stdout, stderr, status = Open3.capture3("qpdf", "--check", path)

      return if [0, 3].include?(status.exitstatus)

      raise AdapterError, <<~MESSAGE
        Extracted PDF for page #{page} is invalid: #{path}

        qpdf exit status: #{status.exitstatus}

        STDOUT:
        #{stdout}

        STDERR:
        #{stderr}
      MESSAGE
    end 

    def pdf_page_labels(input, pages)
      PageLabels.extract(input: input, pages: pages)
    end

    def pdf_visible_page_numbers(input, pages, total_pages)
      VisiblePageNumbers.extract(
        input: input,
        pages: pages,
        total_pages: total_pages
      )
    end

    def pdf_visual_page_numbers(input, pages, total_pages, known_labels, progress = nil)
      preprocessing_progress = if progress
        lambda do |current:, total_pages:|
          if current.zero?
            notify(progress, :start_preprocessing, total_pages: total_pages)
          else
            notify(
              progress,
              :preprocessing_advance,
              current: current,
              total_pages: total_pages
            )
          end
        end
      end

      VisualPageNumbers.extract(
        input: input,
        pages: pages,
        total_pages: total_pages,
        known_labels: known_labels,
        progress: preprocessing_progress
      )
    end

    def pdf_inferred_page_numbers(pages, total_pages, known_labels)
      PageNumberSequence.infer(
        pages: pages,
        known_labels: known_labels,
        total_pages: total_pages
      )
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

    def resolve_title(input, title)
      value = title.to_s.strip
      return value unless value.empty?

      File.basename(input, File.extname(input))
    end

    def output_filename(title)
      suffix = @config.dig("output", "filename_suffix").to_s
      stem = title.gsub(/[\/\\\s\x00-\x1f]+/, "_")
      "#{stem}#{suffix}"
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
