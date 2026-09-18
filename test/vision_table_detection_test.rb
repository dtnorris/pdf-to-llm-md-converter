# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/vision_reading_order"

class VisionTableDetectionTest < Minitest::Test
  Observation = PdfToLlmMd::VisionReadingOrder::Observation

  def test_marks_repeated_four_cell_rows_as_table_like
    observations = []
    8.times do |row|
      y = 0.86 - (row * 0.07)
      [
        [0.06, "CR 5"],
        [0.29, "AC 16"],
        [0.52, "HP 80"],
        [0.75, "+7 / 12"]
      ].each do |x, text|
        observations << obs(text, x: x, y: y, width: 0.14)
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


  def test_four_aligned_long_stat_cells_are_not_classified_as_table_like
    observations = []
    8.times do |row|
      y = 0.86 - (row * 0.07)
      [0.05, 0.28, 0.51, 0.74].each_with_index do |x, column|
        observations << obs(
          "Monster #{column} substantial stat block field #{row}",
          x: x,
          y: y,
          width: 0.18
        )
      end
    end

    result = orderer.render(observations)

    refute result.diagnostics.fetch("table_like")
    assert_operator result.diagnostics.fetch("table_rows"), :<, 4
  end

  def test_aligned_adventure_prose_fragments_are_not_classified_as_table_like
    observations = []
    8.times do |row|
      y = 0.86 - (row * 0.07)
      cells = [
        [0.04, "Room #{row}"],
        [0.22, "DC 15"],
        [0.42, "Adventurers discover a hidden mechanism #{row}"],
        [0.70, "The creature retreats through the eastern passage #{row}"]
      ]
      cells.each do |x, text|
        observations << obs(text, x: x, y: y, width: 0.18)
      end
    end

    result = orderer.render(observations)

    refute result.diagnostics.fetch("table_like")
    assert_operator result.diagnostics.fetch("table_rows"), :<, 4
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
