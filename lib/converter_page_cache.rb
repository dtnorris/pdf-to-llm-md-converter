# frozen_string_literal: true

require "digest"
require_relative "converter"
require_relative "page_extraction_cache"

module PdfToLlmMd
  module ConverterPageCache
    attr_reader :page_cache_stats

    def initialize(config_path:, adapter: nil)
      @page_cache_settings_sha256 = Digest::SHA256.file(
        File.expand_path(config_path)
      ).hexdigest
      super
    end

    def convert(
      input:,
      output_dir:,
      title: nil,
      from_page: 1,
      to_page: nil,
      printed_page_offset: nil,
      progress: nil
    )
      configure_page_cache!(output_dir)

      result = super(
        input: input,
        output_dir: output_dir,
        title: title,
        from_page: from_page,
        to_page: to_page,
        printed_page_offset: printed_page_offset,
        progress: progress
      )

      report_page_cache if cache_reporting?
      result
    end

    private

    def extract_pages(input:, pages:, progress: nil)
      unless page_cache_enabled?
        @page_cache_stats = {
          enabled: false,
          root: nil,
          hits: 0,
          misses: pages.length,
          refreshed: 0
        }.freeze
        return super
      end

      outside_range = @page_cache_refresh_pages - pages
      unless outside_range.empty?
        raise ArgumentError,
              "Refresh pages outside selected range: #{outside_range.join(', ')}"
      end

      cache = PageExtractionCache.new(
        root: @page_cache_root,
        input_path: input,
        settings_sha256: @page_cache_settings_sha256,
        adapter: adapter_name(@adapter)
      )

      documents = {}
      completed = 0
      refresh = @page_cache_refresh_pages.to_h { |page| [page, true] }
      stats = {
        enabled: true,
        root: cache.root,
        hits: 0,
        misses: 0,
        refreshed: 0
      }
      mutex = Mutex.new

      Dir.mktmpdir("pdf-to-llm-md-") do |tmpdir|
        worker_count = Integer(
          @config.dig("processing", "parallel_workers") || 4
        ).clamp(1, 8)

        queue = Queue.new
        pages.each { |page| queue << page }

        workers = worker_count.times.map do
          Thread.new do
            loop do
              page = queue.pop(true)
              refresh_page = refresh.key?(page)

              # Delete before attempting a targeted repair so a failed refresh
              # cannot silently fall back to the old cached result later.
              cache.invalidate(page) if refresh_page

              extraction = cache.fetch(page) unless refresh_page
              cache_hit = !extraction.nil?

              unless extraction
                page_pdf = extract_page(
                  input: input,
                  page: page,
                  tmpdir: tmpdir
                )

                page_output = File.join(
                  tmpdir,
                  "docling-page-#{format('%04d', page)}"
                )

                extraction = if @adapter.respond_to?(:convert_with_metadata)
                  @adapter.convert_with_metadata(
                    input: page_pdf,
                    output_dir: page_output
                  )
                else
                  ExtractionResult.new(
                    markdown: @adapter.convert(
                      input: page_pdf,
                      output_dir: page_output
                    ),
                    backend: adapter_name(@adapter),
                    diagnostics: {}.freeze
                  )
                end

                cache.store(page, extraction)
              end

              mutex.synchronize do
                documents[page] = extraction.markdown
                @extraction_results[page] = extraction
                stats[:hits] += 1 if cache_hit
                stats[:refreshed] += 1 if refresh_page
                stats[:misses] += 1 unless cache_hit || refresh_page
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
      end

      cache.verify_source!
      @page_cache_stats = stats.freeze
      documents
    end

    def configure_page_cache!(output_dir)
      enabled = ENV.fetch("PDF_TO_LLM_PAGE_CACHE", "0")
      @page_cache_enabled = enabled == "1"

      refresh_text = ENV.fetch("PDF_TO_LLM_REFRESH_PAGES", "")
      @page_cache_refresh_pages = refresh_text.split(",").reject(&:empty?).map do |value|
        Integer(value, 10)
      end.uniq.sort

      if !@page_cache_enabled && !@page_cache_refresh_pages.empty?
        raise ArgumentError,
              "Refresh pages require page cache to be enabled"
      end

      explicit_root = ENV["PDF_TO_LLM_PAGE_CACHE_DIR"].to_s.strip
      @page_cache_root = if explicit_root.empty?
        File.expand_path(File.join(output_dir, ".page-cache"))
      else
        File.expand_path(explicit_root)
      end
    rescue ArgumentError
      raise ArgumentError, "PDF_TO_LLM_REFRESH_PAGES must contain positive integer PDF pages"
    end

    def page_cache_enabled?
      @page_cache_enabled == true
    end

    def cache_reporting?
      ENV.fetch("PDF_TO_LLM_PAGE_CACHE_REPORT", "0") == "1"
    end

    def report_page_cache
      stats = @page_cache_stats
      return unless stats

      if stats.fetch(:enabled)
        puts "Page cache: #{stats.fetch(:hits)} hit(s), " \
             "#{stats.fetch(:misses)} miss(es), " \
             "#{stats.fetch(:refreshed)} refreshed"
        puts "Page cache directory: #{stats.fetch(:root)}"
      else
        puts "Page cache: disabled"
      end
    end
  end

  Converter.prepend(ConverterPageCache)
end
