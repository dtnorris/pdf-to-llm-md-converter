# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "extraction_result"

module PdfToLlmMd
  class PageExtractionCache
    SCHEMA = "pdf-to-llm-md/page-extraction-cache/v0.1"

    class Error < StandardError; end

    attr_reader :root, :namespace_dir

    def initialize(root:, input_path:, settings_sha256:, adapter:)
      @root = File.expand_path(root)
      @input_path = File.expand_path(input_path)
      @source_sha256 = Digest::SHA256.file(@input_path).hexdigest
      @settings_sha256 = settings_sha256.to_s
      @adapter = adapter.to_s

      raise Error, "settings SHA-256 is required" if @settings_sha256.empty?
      raise Error, "adapter identity is required" if @adapter.empty?

      namespace_identity = [
        SCHEMA,
        @source_sha256,
        @settings_sha256,
        @adapter
      ]
      @namespace_key = Digest::SHA256.hexdigest(JSON.generate(namespace_identity))
      @namespace_dir = File.join(@root, @namespace_key)

      FileUtils.mkdir_p(@namespace_dir)
      write_manifest
    rescue Errno::ENOENT
      raise Error, "Cache input PDF not found: #{@input_path}"
    end

    def fetch(page)
      page = positive_page(page)
      path = entry_path(page)
      return nil unless File.file?(path)

      payload = JSON.parse(File.read(path, encoding: "UTF-8"))
      return nil unless valid_identity?(payload, page)

      result = payload["result"]
      return nil unless result.is_a?(Hash)

      markdown = result["markdown"]
      backend = result["backend"]
      diagnostics = result["diagnostics"]

      return nil unless markdown.is_a?(String)
      return nil unless backend.is_a?(String) && !backend.empty?
      return nil unless diagnostics.is_a?(Hash)
      return nil unless result["markdown_sha256"] == Digest::SHA256.hexdigest(markdown)

      ExtractionResult.new(
        markdown: markdown,
        backend: backend,
        diagnostics: deep_freeze(diagnostics)
      )
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    def store(page, extraction)
      page = positive_page(page)
      markdown = extraction.markdown.to_s

      payload = identity_payload(page).merge(
        "result" => {
          "backend" => extraction.backend.to_s,
          "diagnostics" => stringify_keys(extraction.diagnostics || {}),
          "markdown_sha256" => Digest::SHA256.hexdigest(markdown),
          "markdown" => markdown
        }
      )

      atomic_write(entry_path(page), JSON.pretty_generate(payload) + "\n")
    end

    def invalidate(page)
      FileUtils.rm_f(entry_path(positive_page(page)))
    end

    def verify_source!
      current = Digest::SHA256.file(@input_path).hexdigest
      return true if current == @source_sha256

      discard_namespace!
      raise Error, "Source PDF changed during conversion; discarded page cache namespace"
    rescue Errno::ENOENT
      discard_namespace!
      raise Error, "Source PDF disappeared during conversion; discarded page cache namespace"
    end

    private

    def discard_namespace!
      FileUtils.rm_rf(@namespace_dir)
    end

    def entry_path(page)
      File.join(@namespace_dir, "page-#{format('%04d', page)}.json")
    end

    def write_manifest
      payload = {
        "schema" => SCHEMA,
        "namespace_key" => @namespace_key,
        "source_sha256" => @source_sha256,
        "settings_sha256" => @settings_sha256,
        "adapter" => @adapter
      }

      atomic_write(
        File.join(@namespace_dir, "manifest.json"),
        JSON.pretty_generate(payload) + "\n"
      )
    end

    def identity_payload(page)
      {
        "schema" => SCHEMA,
        "namespace_key" => @namespace_key,
        "source_sha256" => @source_sha256,
        "settings_sha256" => @settings_sha256,
        "adapter" => @adapter,
        "page" => page
      }
    end

    def valid_identity?(payload, page)
      payload["schema"] == SCHEMA &&
        payload["namespace_key"] == @namespace_key &&
        payload["source_sha256"] == @source_sha256 &&
        payload["settings_sha256"] == @settings_sha256 &&
        payload["adapter"] == @adapter &&
        payload["page"] == page
    end

    def positive_page(value)
      page = Integer(value)
      raise Error, "cache page must be positive" unless page.positive?

      page
    rescue ArgumentError, TypeError
      raise Error, "cache page must be an integer"
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = stringify_keys(child)
        end
      when Array
        value.map { |child| stringify_keys(child) }
      else
        value
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |child| deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(temporary, content, encoding: "UTF-8")
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary)
    end
  end
end
