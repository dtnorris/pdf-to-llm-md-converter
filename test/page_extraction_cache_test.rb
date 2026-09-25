# frozen_string_literal: true

require "digest"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/extraction_result"
require_relative "../lib/page_extraction_cache"

class PageExtractionCacheTest < Minitest::Test
  def test_cache_entry_is_bound_to_source_settings_adapter_and_page
    Dir.mktmpdir do |tmpdir|
      source = File.join(tmpdir, "book.pdf")
      File.write(source, "source-a")
      root = File.join(tmpdir, "cache")
      settings = Digest::SHA256.hexdigest("settings-a")

      cache = PdfToLlmMd::PageExtractionCache.new(
        root: root,
        input_path: source,
        settings_sha256: settings,
        adapter: "auto"
      )

      cache.store(
        7,
        PdfToLlmMd::ExtractionResult.new(
          markdown: "# cached",
          backend: "apple-vision",
          diagnostics: { "recognized_characters" => 100 }.freeze
        )
      )

      hit = cache.fetch(7)
      assert_equal "# cached", hit.markdown
      assert_equal "apple-vision", hit.backend
      assert_equal 100, hit.diagnostics.fetch("recognized_characters")
      assert_nil cache.fetch(8)

      changed_settings = PdfToLlmMd::PageExtractionCache.new(
        root: root,
        input_path: source,
        settings_sha256: Digest::SHA256.hexdigest("settings-b"),
        adapter: "auto"
      )
      assert_nil changed_settings.fetch(7)

      changed_adapter = PdfToLlmMd::PageExtractionCache.new(
        root: root,
        input_path: source,
        settings_sha256: settings,
        adapter: "docling"
      )
      assert_nil changed_adapter.fetch(7)

      File.write(source, "source-b")
      changed_source = PdfToLlmMd::PageExtractionCache.new(
        root: root,
        input_path: source,
        settings_sha256: settings,
        adapter: "auto"
      )
      assert_nil changed_source.fetch(7)
    end
  end

  def test_invalidate_removes_exact_page_only
    Dir.mktmpdir do |tmpdir|
      source = File.join(tmpdir, "book.pdf")
      File.write(source, "source")

      cache = PdfToLlmMd::PageExtractionCache.new(
        root: File.join(tmpdir, "cache"),
        input_path: source,
        settings_sha256: Digest::SHA256.hexdigest("settings"),
        adapter: "auto"
      )

      result = PdfToLlmMd::ExtractionResult.new(
        markdown: "cached",
        backend: "docling",
        diagnostics: {}.freeze
      )

      cache.store(1, result)
      cache.store(2, result)
      cache.invalidate(1)

      assert_nil cache.fetch(1)
      refute_nil cache.fetch(2)
    end
  end
end
