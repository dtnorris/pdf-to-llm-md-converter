# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require_relative "docling_adapter"
require_relative "vision_reading_order"

module PdfToLlmMd
  class AppleVisionAdapter
    def initialize(config:)
      @config = config
    end

    def available?
      darwin? && command_available?("xcrun") && command_available?("pdftoppm")
    end

    def convert(input:, output_dir:)
      unless available?
        raise AdapterError,
              "Apple Vision experimental backend requires macOS, xcrun, and pdftoppm"
      end

      FileUtils.mkdir_p(output_dir)
      stem = File.basename(input, File.extname(input))

      Dir.mktmpdir("pdf-to-llm-vision-") do |tmpdir|
        png_prefix = File.join(tmpdir, stem)
        png_path = "#{png_prefix}.png"
        tsv_path = File.join(tmpdir, "#{stem}.vision.tsv")

        render_page(input: input, output_prefix: png_prefix)
        run_vision(input: png_path, output: tsv_path)

        orderer = VisionReadingOrder.new(config: @config)
        result = orderer.render(orderer.load_tsv(tsv_path))

        File.write(
          File.join(output_dir, "#{stem}.md"),
          result.markdown,
          encoding: "UTF-8"
        )
        FileUtils.cp(tsv_path, File.join(output_dir, "#{stem}.vision.tsv"))
        File.write(
          File.join(output_dir, "#{stem}.vision-order.json"),
          JSON.pretty_generate(result.diagnostics) + "\n",
          encoding: "UTF-8"
        )

        result.markdown
      end
    end

    private

    def render_page(input:, output_prefix:)
      run!(
        "pdftoppm",
        "-singlefile",
        "-r",
        render_dpi.to_s,
        "-png",
        File.expand_path(input),
        output_prefix
      )
    end

    def run_vision(input:, output:)
      run!(
        "xcrun",
        "swift",
        File.expand_path("apple_vision_ocr.swift", __dir__),
        input,
        output,
        recognition_language
      )
    end

    def run!(*command)
      timeout_seconds = Integer(@config.dig("vision", "timeout_seconds") || 120)
      stdout = stderr = status = nil

      Timeout.timeout(timeout_seconds) do
        stdout, stderr, status = Open3.capture3(*command)
      end

      return if status.success?

      raise AdapterError, <<~MESSAGE
        Apple Vision command failed (exit #{status.exitstatus}): #{command.inspect}

        STDOUT:
        #{stdout}

        STDERR:
        #{stderr}
      MESSAGE
    rescue Timeout::Error
      raise AdapterError, "Apple Vision command exceeded timeout of #{timeout_seconds} seconds"
    rescue Errno::ENOENT => e
      raise AdapterError, "Unable to start Apple Vision dependency: #{e.message}"
    end

    def render_dpi
      Integer(@config.dig("vision", "render_dpi") || 300)
    end

    def recognition_language
      @config.dig("vision", "recognition_language").to_s.strip.then do |value|
        value.empty? ? "en-US" : value
      end
    end

    def darwin?
      RbConfig::CONFIG.fetch("host_os").include?("darwin")
    end

    def command_available?(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, command))
      end
    end
  end
end
