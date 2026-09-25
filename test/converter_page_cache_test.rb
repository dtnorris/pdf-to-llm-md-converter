# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/converter_page_cache"
require_relative "../lib/extraction_result"

class ConverterPageCacheTest < Minitest::Test
  class TestConverter < PdfToLlmMd::Converter
    private

    def pdf_page_count(_input)
      3
    end

    def pdf_page_labels(_input, pages)
      pages.to_h { |page| [page, page.to_s] }
    end

    def extract_page(input:, page:, tmpdir:)
      path = File.join(tmpdir, "page-#{page}.pdf")
      File.write(path, "fake isolated page #{page}")
      path
    end
  end

  class CountingAdapter
    attr_reader :calls

    def initialize
      @calls = []
      @mutex = Mutex.new
    end

    def convert_with_metadata(input:, output_dir:)
      FileUtils.mkdir_p(output_dir)
      page = File.basename(input)[/\d+/].to_i
      @mutex.synchronize { @calls << page }

      PdfToLlmMd::ExtractionResult.new(
        markdown: "# Page #{page}\ncontent",
        backend: "test",
        diagnostics: { "page" => page }.freeze
      )
    end
  end

  class OtherCountingAdapter < CountingAdapter
  end

  def setup
    @original_env = {
      "PDF_TO_LLM_PAGE_CACHE" => ENV["PDF_TO_LLM_PAGE_CACHE"],
      "PDF_TO_LLM_PAGE_CACHE_DIR" => ENV["PDF_TO_LLM_PAGE_CACHE_DIR"],
      "PDF_TO_LLM_PAGE_CACHE_REPORT" => ENV["PDF_TO_LLM_PAGE_CACHE_REPORT"],
      "PDF_TO_LLM_REFRESH_PAGES" => ENV["PDF_TO_LLM_REFRESH_PAGES"]
    }
    ENV["PDF_TO_LLM_PAGE_CACHE"] = "1"
    ENV["PDF_TO_LLM_PAGE_CACHE_REPORT"] = "0"
    ENV.delete("PDF_TO_LLM_PAGE_CACHE_DIR")
    ENV["PDF_TO_LLM_REFRESH_PAGES"] = ""
  end

  def teardown
    @original_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_reuses_unchanged_pages_and_targeted_refresh_reextracts_only_requested_page
    Dir.mktmpdir do |tmpdir|
      input, output_dir, config_path = fixture(tmpdir)
      adapter = CountingAdapter.new

      first = TestConverter.new(config_path: config_path, adapter: adapter).convert(
        input: input,
        output_dir: output_dir
      )
      assert first.validation.valid
      assert_equal [1, 2, 3], adapter.calls.sort

      second_converter = TestConverter.new(config_path: config_path, adapter: adapter)
      second_converter.convert(input: input, output_dir: output_dir)
      assert_equal [1, 2, 3], adapter.calls.sort
      assert_equal 3, second_converter.page_cache_stats.fetch(:hits)

      ENV["PDF_TO_LLM_REFRESH_PAGES"] = "2"
      third_converter = TestConverter.new(config_path: config_path, adapter: adapter)
      third_converter.convert(input: input, output_dir: output_dir)

      assert_equal [1, 2, 2, 3], adapter.calls.sort
      assert_equal 2, third_converter.page_cache_stats.fetch(:hits)
      assert_equal 1, third_converter.page_cache_stats.fetch(:refreshed)
    end
  end

  def test_changed_source_settings_or_adapter_do_not_reuse_cache
    Dir.mktmpdir do |tmpdir|
      input, output_dir, config_path = fixture(tmpdir)
      first_adapter = CountingAdapter.new

      TestConverter.new(config_path: config_path, adapter: first_adapter).convert(
        input: input,
        output_dir: output_dir
      )
      assert_equal 3, first_adapter.calls.length

      File.write(input, "%PDF changed source bytes")
      source_converter = TestConverter.new(config_path: config_path, adapter: first_adapter)
      source_converter.convert(input: input, output_dir: output_dir)
      assert_equal 0, source_converter.page_cache_stats.fetch(:hits)
      assert_equal 6, first_adapter.calls.length

      write_config(config_path, workers: 2)
      settings_converter = TestConverter.new(config_path: config_path, adapter: first_adapter)
      settings_converter.convert(input: input, output_dir: output_dir)
      assert_equal 0, settings_converter.page_cache_stats.fetch(:hits)
      assert_equal 9, first_adapter.calls.length

      second_adapter = OtherCountingAdapter.new
      adapter_converter = TestConverter.new(config_path: config_path, adapter: second_adapter)
      adapter_converter.convert(input: input, output_dir: output_dir)
      assert_equal 0, adapter_converter.page_cache_stats.fetch(:hits)
      assert_equal 3, second_adapter.calls.length
    end
  end

  private

  def fixture(tmpdir)
    input = File.join(tmpdir, "book.pdf")
    output_dir = File.join(tmpdir, "build")
    config_path = File.join(tmpdir, "conversion.yml")

    File.write(input, "%PDF stable source")
    write_config(config_path, workers: 1)

    [input, output_dir, config_path]
  end

  def write_config(path, workers:)
    File.write(
      path,
      {
        "processing" => { "parallel_workers" => workers },
        "output" => {
          "filename_suffix" => "_LLM_Edition.md",
          "include_front_matter" => true,
          "conversion_label" => "test"
        },
        "validation" => {
          "require_page_markers" => true,
          "minimum_characters_per_page" => 0,
          "maximum_blank_page_ratio" => 1.0,
          "flag_patterns" => []
        }
      }.to_yaml
    )
  end
end
