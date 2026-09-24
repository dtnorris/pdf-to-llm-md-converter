# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"

module PdfToLlmMd
  ReceiptWriteResult = Data.define(:path, :payload)
  ReceiptReviewResult = Data.define(:path, :payload, :unresolved_pages)

  class ConversionReceipt
    SCHEMA = "pdf-to-llm-md/conversion-receipt/v0.1"

    class Error < StandardError; end

    class << self
      def write(input_path:, result:)
        input_path = File.expand_path(input_path)
        output_path = File.expand_path(result.output_path)
        path = receipt_path_for(output_path)
        payload = build_payload(
          input_path: input_path,
          output_path: output_path,
          validation: result.validation,
          extraction_quality: result.extraction_quality,
          pages: result.pages
        )

        atomic_write(path, JSON.pretty_generate(payload) + "\n")
        ReceiptWriteResult.new(path: path, payload: payload.freeze)
      end

      def load(path)
        path = File.expand_path(path)
        payload = JSON.parse(File.read(path, encoding: "UTF-8"))
        validate_schema!(payload)
        payload
      rescue Errno::ENOENT
        raise Error, "Conversion receipt not found: #{path}"
      rescue JSON::ParserError => error
        raise Error, "Invalid conversion receipt JSON: #{error.message}"
      end

      def inspect_page(path:, page:)
        payload = load(path)
        verify_bound_files!(payload)
        page = Integer(page)
        issues = unresolved_issues(payload).select { |issue| issue.fetch("page") == page }

        raise Error, "No unresolved extraction-quality issues for PDF page #{page}" if issues.empty?

        {
          "receipt_path" => File.expand_path(path),
          "state" => payload.fetch("state"),
          "page" => page,
          "issues" => issues,
          "source" => payload.fetch("source"),
          "output" => payload.fetch("output")
        }.freeze
      rescue ArgumentError, TypeError
        raise Error, "PDF page must be an integer"
      end

      def accept_page_exception(path:, page:, reason:)
        payload = load(path)
        verify_bound_files!(payload)
        page = Integer(page)
        reason = reason.to_s.strip
        raise Error, "Exception reason must not be blank" if reason.empty?

        issues = unresolved_issues(payload).select { |issue| issue.fetch("page") == page }
        raise Error, "No unresolved extraction-quality issues for PDF page #{page}" if issues.empty?

        exception = {
          "page" => page,
          "reason" => reason,
          "issue_fingerprints" => issues.map { |issue| issue.fetch("fingerprint") }.sort,
          "source_sha256" => payload.dig("source", "sha256"),
          "output_sha256" => payload.dig("output", "sha256")
        }

        payload.fetch("page_exceptions") << exception
        refresh_review_state!(payload)

        absolute_path = File.expand_path(path)
        atomic_write(absolute_path, JSON.pretty_generate(payload) + "\n")

        ReceiptReviewResult.new(
          path: absolute_path,
          payload: payload.freeze,
          unresolved_pages: unresolved_issues(payload).map { |issue| issue.fetch("page") }.uniq.sort.freeze
        )
      rescue ArgumentError, TypeError
        raise Error, "PDF page must be an integer"
      end

      def receipt_path_for(output_path)
        output_path = File.expand_path(output_path)
        extension = File.extname(output_path)
        stem = extension.empty? ? output_path : output_path.delete_suffix(extension)
        "#{stem}.conversion-receipt.json"
      end

      private

      def build_payload(input_path:, output_path:, validation:, extraction_quality:, pages:)
        issues = extraction_quality.issues.map { |issue| serialize_issue(issue) }
        state = if !validation.valid
          "invalid"
        elsif issues.empty?
          "ready"
        else
          "needs_page_review"
        end

        {
          "schema" => SCHEMA,
          "state" => state,
          "downstream_ready" => %w[ready ready_with_exceptions].include?(state),
          "source" => file_identity(input_path),
          "output" => file_identity(output_path),
          "page_range" => {
            "first" => pages.min,
            "last" => pages.max,
            "count" => pages.length
          },
          "structural_validation" => {
            "valid" => validation.valid,
            "errors" => validation.errors,
            "warnings" => validation.warnings,
            "stats" => stringify_keys(validation.stats)
          },
          "extraction_quality" => {
            "machine_valid" => extraction_quality.valid,
            "issues" => issues,
            "pages" => stringify_keys(extraction_quality.pages)
          },
          "page_exceptions" => [],
          "unresolved_issue_fingerprints" => issues.map { |issue| issue.fetch("fingerprint") }.sort
        }
      end

      def serialize_issue(issue)
        issue_hash = {
          "page" => issue.page,
          "backend" => issue.backend.to_s,
          "reason" => issue.reason.to_s,
          "diagnostics" => stringify_keys(issue.diagnostics || {})
        }
        issue_hash["fingerprint"] = Digest::SHA256.hexdigest(JSON.generate(canonicalize(issue_hash)))
        issue_hash.freeze
      end

      def refresh_review_state!(payload)
        unresolved = unresolved_issues(payload)
        payload["unresolved_issue_fingerprints"] = unresolved.map { |issue| issue.fetch("fingerprint") }.sort

        payload["state"] = if !payload.dig("structural_validation", "valid")
          "invalid"
        elsif unresolved.empty? && payload.dig("extraction_quality", "issues").to_a.empty?
          "ready"
        elsif unresolved.empty?
          "ready_with_exceptions"
        else
          "needs_page_review"
        end
        payload["downstream_ready"] = %w[ready ready_with_exceptions].include?(payload.fetch("state"))
      end

      def unresolved_issues(payload)
        accepted = payload.fetch("page_exceptions", []).flat_map do |exception|
          Array(exception["issue_fingerprints"])
        end.to_h { |fingerprint| [fingerprint, true] }

        payload.dig("extraction_quality", "issues").to_a.reject do |issue|
          accepted.key?(issue.fetch("fingerprint"))
        end
      end

      def verify_bound_files!(payload)
        verify_file_identity!(payload.fetch("source"), label: "Source PDF")
        verify_file_identity!(payload.fetch("output"), label: "Markdown output")
      end

      def verify_file_identity!(identity, label:)
        path = identity.fetch("path")
        expected_sha256 = identity.fetch("sha256")
        raise Error, "#{label} no longer exists: #{path}" unless File.file?(path)

        actual_sha256 = Digest::SHA256.file(path).hexdigest
        return if actual_sha256 == expected_sha256

        raise Error, "#{label} changed since conversion: #{path}"
      end

      def file_identity(path)
        raise Error, "Receipt-bound file not found: #{path}" unless File.file?(path)

        {
          "path" => File.expand_path(path),
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path)
        }
      end

      def validate_schema!(payload)
        schema = payload["schema"]
        return if schema == SCHEMA

        raise Error, "Unsupported conversion receipt schema: #{schema.inspect}"
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

      def canonicalize(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
        when Array
          value.map { |child| canonicalize(child) }
        else
          value
        end
      end

      def atomic_write(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.tmp-#{Process.pid}"
        File.write(temporary, content, encoding: "UTF-8")
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary)
      end
    end
  end
end
