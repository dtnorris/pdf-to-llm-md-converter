# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/page_number_sequence"

class PageNumberSequenceTest < Minitest::Test
  def test_infers_missing_pages_forward_and_backward_from_three_direct_anchors
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (24..30).to_a,
      known_labels: { 25 => "22", 26 => "23", 27 => "24" },
      total_pages: 290
    )

    assert_equal(
      { 24 => "21", 28 => "25", 29 => "26", 30 => "27" },
      inferred
    )
  end

  def test_requires_three_consecutive_direct_anchors
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (24..30).to_a,
      known_labels: { 26 => "23", 27 => "24" },
      total_pages: 290
    )

    assert_equal({}, inferred)
  end

  def test_limits_inference_to_three_pages_from_a_direct_run
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (20..34).to_a,
      known_labels: { 25 => "22", 26 => "23", 27 => "24" },
      total_pages: 290
    )

    assert_equal(
      {
        22 => "19", 23 => "20", 24 => "21",
        28 => "25", 29 => "26", 30 => "27"
      },
      inferred
    )
    refute inferred.key?(21)
    refute inferred.key?(31)
  end

  def test_existing_label_is_a_barrier_and_is_never_overwritten
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (24..33).to_a,
      known_labels: {
        25 => "22", 26 => "23", 27 => "24",
        29 => "Appendix"
      },
      total_pages: 290
    )

    assert_equal({ 24 => "21", 28 => "25" }, inferred)
    refute inferred.key?(29)
    refute inferred.key?(30)
  end

  def test_conflicting_qualified_runs_do_not_guess_across_the_gap
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (25..33).to_a,
      known_labels: {
        25 => "22", 26 => "23", 27 => "24",
        31 => "40", 32 => "41", 33 => "42"
      },
      total_pages: 290
    )

    assert_equal({}, inferred)
  end

  def test_non_numeric_labels_do_not_establish_a_sequence
    inferred = PdfToLlmMd::PageNumberSequence.infer(
      pages: (1..6).to_a,
      known_labels: { 2 => "ii", 3 => "iii", 4 => "iv" },
      total_pages: 10
    )

    assert_equal({}, inferred)
  end
end
