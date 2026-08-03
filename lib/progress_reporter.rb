# frozen_string_literal: true

module PdfToLlmMd
  class ProgressReporter
    BAR_WIDTH = 20

    def initialize(
      io: $stdout,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @io = io
      @clock = clock
      @started_at = nil
    end

    def start
      @started_at = @clock.call
    end

    def inspect_pdf(total_pages:)
      @io.puts "Inspecting PDF: #{total_pages} pages"
      flush
    end

    def start_conversion(total_pages:)
      @io.puts
      @io.puts "Converting..."
      render_bar(current: 0, total_pages: total_pages)
    end

    def advance(current:, total_pages:)
      render_bar(current: current, total_pages: total_pages)
      @io.puts if current >= total_pages
      flush
    end

    def validation(result:)
      stats = result.stats

      @io.puts
      @io.puts "Validation"
      @io.puts "✓ #{stats.fetch(:page_markers)} page markers"

      print_collection_result(
        values: stats.fetch(:missing_pages),
        success: "✓ no missing pages",
        failure_label: "✗ missing pages"
      )

      print_collection_result(
        values: stats.fetch(:duplicate_pages),
        success: "✓ no duplicates",
        failure_label: "✗ duplicate pages"
      )

      flagged_pages = stats.fetch(:flagged_pages)

      if flagged_pages.empty?
        @io.puts "✓ no OCR warnings"
      else
        @io.puts warning_line(
          flagged_pages.length,
          "page contained OCR warnings",
          "pages contained OCR warnings"
        )
      end

      short_page_count = stats.fetch(:short_pages)

      if short_page_count.positive?
        @io.puts warning_line(
          short_page_count,
          "page was below the minimum character count",
          "pages were below the minimum character count"
        )
      end

      result.errors.each do |error|
        next if error.start_with?("Missing page markers:")
        next if error.start_with?("Duplicate page markers:")

        @io.puts "✗ #{error}"
      end

      flush
    end

    def finish(output_path:)
      elapsed = @started_at ? @clock.call - @started_at : 0

      @io.puts
      @io.puts "Finished in #{format_duration(elapsed)}"
      @io.puts
      @io.puts "Output:"
      @io.puts output_path
      flush
    end

    private

    def render_bar(current:, total_pages:)
      ratio = total_pages.zero? ? 1.0 : current.fdiv(total_pages)
      filled = (ratio * BAR_WIDTH).round.clamp(0, BAR_WIDTH)
      bar = "#{'=' * filled}#{' ' * (BAR_WIDTH - filled)}"

      @io.print "\r[#{bar}] #{current}/#{total_pages}"
      flush
    end

    def print_collection_result(values:, success:, failure_label:)
      if values.empty?
        @io.puts success
      else
        @io.puts "#{failure_label}: #{values.join(', ')}"
      end
    end

    def warning_line(count, singular, plural)
      "⚠ #{count} #{count == 1 ? singular : plural}"
    end

    def format_duration(elapsed)
      total_seconds = elapsed.round
      hours, remainder = total_seconds.divmod(3600)
      minutes, seconds = remainder.divmod(60)

      parts = []
      parts << "#{hours}h" if hours.positive?
      parts << "#{minutes}m" if minutes.positive?
      parts << "#{seconds}s" if seconds.positive? || parts.empty?
      parts.join(" ")
    end

    def flush
      @io.flush
    end
  end
end
