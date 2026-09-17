# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/vision_reading_order"

class VisionReadingOrderTest < Minitest::Test
  Observation = PdfToLlmMd::VisionReadingOrder::Observation

  def test_infers_one_column_for_continuation_layout
    result = orderer.render([
      obs("4. The dark sun", x: 0.10, y: 0.80, width: 0.25),
      obs("Continuation prose one", x: 0.08, y: 0.70, width: 0.32),
      obs("Continuation prose two", x: 0.12, y: 0.60, width: 0.28),
      obs("5. The dragon", x: 0.09, y: 0.45, width: 0.22)
    ])

    assert_equal 1, result.diagnostics.fetch("columns")
    assert_operator result.markdown.index("4. The dark sun"), :<, result.markdown.index("5. The dragon")
  end

  def test_infers_two_columns_and_orders_left_region_before_right_region
    rows = []
    5.times do |index|
      rows << obs("Left prose #{index}", x: 0.08, y: 0.85 - (index * 0.08), width: 0.30)
      rows << obs("Right prose #{index}", x: 0.64, y: 0.85 - (index * 0.08), width: 0.28)
    end

    result = orderer.render(rows)

    assert_equal 2, result.diagnostics.fetch("columns")
    assert_operator result.markdown.index("Left prose 4"), :<, result.markdown.index("Right prose 0")
  end

  def test_infers_three_columns_for_stat_blocks
    rows = []
    [0.08, 0.37, 0.66].each_with_index do |x, column|
      6.times do |index|
        rows << obs("Monster #{column} stat prose #{index}", x: x, y: 0.88 - (index * 0.08), width: 0.23)
      end
    end

    result = orderer.render(rows)

    assert_equal 3, result.diagnostics.fetch("columns")
    assert_operator result.markdown.index("Monster 0 stat prose 5"), :<, result.markdown.index("Monster 1 stat prose 0")
    assert_operator result.markdown.index("Monster 1 stat prose 5"), :<, result.markdown.index("Monster 2 stat prose 0")
  end

  def test_drops_neighboring_page_edge_bleed
    result = orderer.render([
      obs("neighboring photographed page", x: 0.005, y: 0.8, width: 0.18),
      obs("Actual adventure prose one", x: 0.10, y: 0.70, width: 0.35),
      obs("Actual adventure prose two", x: 0.10, y: 0.60, width: 0.35)
    ])

    assert_equal 1, result.diagnostics.fetch("edge_dropped")
    refute_includes result.markdown, "neighboring photographed page"
    assert_includes result.markdown, "Actual adventure prose one"
  end

  def test_drops_isolated_map_numbers_without_dropping_encounter_text
    rows = []
    4.times do |index|
      rows << obs("Left narrative #{index}", x: 0.07, y: 0.85 - (index * 0.08), width: 0.28)
      rows << obs("Right narrative #{index}", x: 0.67, y: 0.85 - (index * 0.08), width: 0.25)
    end
    rows << obs("20", x: 0.49, y: 0.50, width: 0.02)
    rows << obs("6 x Hobgoblins", x: 0.68, y: 0.45, width: 0.16)

    result = orderer.render(rows)

    assert_equal 1, result.diagnostics.fetch("map_noise_dropped")
    refute_match(/^20$/m, result.markdown)
    assert_includes result.markdown, "6 x Hobgoblins"
  end

  def test_load_tsv_preserves_unescaped_quotes_from_vision
    Tempfile.create(["vision", ".tsv"]) do |file|
      file.write("confidence\tx\ty\twidth\theight\ttext\n")
      file.write(%(1.0000\t0.1\t0.8\t0.3\t0.03\t"The Beards," enter\n))
      file.flush

      observations = orderer.load_tsv(file.path)

      assert_equal 1, observations.length
      assert_equal '"The Beards," enter', observations.first.text
    end
  end

  private

  def orderer
    @orderer ||= PdfToLlmMd::VisionReadingOrder.new(config: {})
  end

  def obs(text, x:, y:, width:, height: 0.03)
    Observation.new(
      confidence: 1.0,
      x: x,
      y: y,
      width: width,
      height: height,
      text: text
    )
  end
end
