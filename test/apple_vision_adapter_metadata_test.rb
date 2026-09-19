# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/apple_vision_adapter"

class AppleVisionAdapterMetadataTest < Minitest::Test
  class StubAdapter < PdfToLlmMd::AppleVisionAdapter
    def available?
      true
    end

    private

    def render_page(input:, output_prefix:)
      File.write("#{output_prefix}.png", "stub", encoding: "UTF-8")
    end

    def run_vision(input:, output:)
      lines = ["confidence\tx\ty\twidth\theight\ttext"]

      8.times do |row|
        y = 0.86 - (row * 0.07)
        [
          [0.06, "CR #{row}"],
          [0.29, "AC #{12 + row}"],
          [0.52, "HP #{40 + row}"],
          [0.75, "+#{row} / #{10 + row}"]
        ].each do |x, text|
          lines << [
            "1.0000",
            x,
            y,
            0.14,
            0.03,
            text
          ].join("\t")
        end
      end

      File.write(output, lines.join("\n") + "\n", encoding: "UTF-8")
    end
  end

  def test_convert_with_metadata_preserves_vision_ordering_diagnostics
    Dir.mktmpdir do |output_dir|
      result = StubAdapter.new(config: {}).convert_with_metadata(
        input: File.join(output_dir, "page.pdf"),
        output_dir: output_dir
      )

      assert_equal "apple-vision", result.backend
      assert result.diagnostics.fetch("table_like")
      assert_operator result.diagnostics.fetch("table_rows"), :>=, 4
      assert_operator result.diagnostics.fetch("table_page_compact_ratio"), :>=, 0.80
      assert_includes result.markdown, "APPLE VISION"
    end
  end
end
