# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/vision_reading_order"

class VisionTableDetectionTest < Minitest::Test
  Observation = PdfToLlmMd::VisionReadingOrder::Observation

  def test_marks_repeated_four_cell_rows_as_table_like
    observations = []
    8.times do |row|
      y = 0.86 - (row * 0.07)
      [0.06, 0.29, 0.52, 0.75].each_with_index do |x, column|
        observations << obs("cell #{row}-#{column}", x: x, y: y, width: 0.14)
      end
    end

    result = orderer.render(observations)

    assert result.diagnostics.fetch("table_like")
    assert_operator result.diagnostics.fetch("table_rows"), :>=, 4
  end

  def test_three_column_stat_block_geometry_is_not_classified_as_table_like
    observations = []
    [0.08, 0.37, 0.66].each_with_index do |x, column|
      8.times do |row|
        observations << obs(
          "Monster #{column} descriptive stat line #{row}",
          x: x,
          y: 0.88 - (row * 0.07),
          width: 0.23
        )
      end
    end

    result = orderer.render(observations)

    refute result.diagnostics.fetch("table_like")
  end

  private

  def orderer
    @orderer ||= PdfToLlmMd::VisionReadingOrder.new(config: {})
  end

  def obs(text, x:, y:, width:)
    Observation.new(
      confidence: 1.0,
      x: x,
      y: y,
      width: width,
      height: 0.03,
      text: text
    )
  end
end
