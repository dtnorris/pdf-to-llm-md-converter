# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "timeout"

module PdfToLlmMd
  class AdapterError < StandardError; end

  class DoclingAdapter
    def initialize(config:)
      @config = config
    end

    def convert(input:, output_dir:)
      FileUtils.mkdir_p(output_dir)
      command = render_command(input: input, output_dir: output_dir)
      stdout, stderr, status = run(command)

      unless status.success?
        raise AdapterError, "Docling failed (exit #{status.exitstatus}): #{stderr.strip}\n#{stdout.strip}"
      end

      markdown_path = locate_markdown(output_dir, input)
      raise AdapterError, "Docling produced no Markdown file in #{output_dir}" unless markdown_path

      File.read(markdown_path, encoding: "UTF-8")
    end

    def available?
      executable = @config.dig("converter", "executable").to_s
      return false if executable.empty?

      system("command -v #{Shellwords.escape(executable)} >/dev/null 2>&1")
    end

    private

    def render_command(input:, output_dir:)
      template = @config.dig("converter", "command").to_s
      format(
        template,
        executable: @config.dig("converter", "executable"),
        input: File.expand_path(input),
        output_dir: File.expand_path(output_dir)
      )
    rescue KeyError => e
      raise AdapterError, "Invalid converter command template: #{e.message}"
    end

    def run(command)
      timeout_seconds = @config.dig("converter", "timeout_seconds").to_i
      Timeout.timeout(timeout_seconds) { Open3.capture3(command) }
    rescue Timeout::Error
      raise AdapterError, "Docling exceeded timeout of #{timeout_seconds} seconds"
    rescue Errno::ENOENT => e
      raise AdapterError, "Unable to start Docling: #{e.message}"
    end

    def locate_markdown(output_dir, input)
      expected = File.join(output_dir, "#{File.basename(input, File.extname(input))}.md")
      return expected if File.file?(expected)

      Dir.glob(File.join(output_dir, "**", "*.md")).max_by { |path| File.mtime(path) }
    end
  end
end
