# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/visual_page_numbers"

class VisualPageNumbersTest < Minitest::Test
  FakeStatus = Struct.new(:success_value) do
    def success?
      success_value
    end
  end

  def test_detects_only_sequence_supported_bottom_corner_numbers
    responses = {
      [26, :right, :color, 6] => tsv("23", left: 650),
      [27, :left, :color, 11] => tsv("24", left: 100),
      [28, :right, :color, 6] => tsv("25", left: 650),
      [29, :left, :color, 6] => tsv("25", left: 100),
      [30, :right, :color, 6] => tsv("27", left: 650)
    }

    with_fake_tools(responses: responses) do
      labels = PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27, 28, 29],
        total_pages: 290
      )

      assert_equal({ 27 => "24", 28 => "25" }, labels)
      refute labels.key?(29), "misread 25 must not be accepted as printed page 26"
    end
  end

  def test_uses_known_numeric_label_to_confirm_visual_candidate_without_ocring_known_page
    commands = []
    responses = {
      [27, :left, :gray, 6] => tsv("24", left: 100)
    }

    with_fake_tools(responses: responses, commands: commands) do
      labels = PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27],
        total_pages: 290,
        known_labels: { 26 => "23" }
      )

      assert_equal({ 27 => "24" }, labels)
    end

    rendered_pages = commands.filter_map do |command|
      next unless command.first == "pdftoppm"

      command.fetch(command.index("-f") + 1).to_i
    end
    refute_includes rendered_pages, 26
  end

  def test_rejects_candidates_that_are_not_at_the_outer_bottom_corner
    responses = {
      [27, :left, :color, 6] => tsv("24", left: 500, top: 100),
      [28, :right, :color, 6] => tsv("25", left: 100, top: 430)
    }

    with_fake_tools(responses: responses) do
      labels = PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27, 28],
        total_pages: 290
      )

      assert_equal({}, labels)
    end
  end

  def test_scrubs_invalid_utf8_from_tesseract_output
    dirty_tsv = tsv("24", left: 100).b
    dirty_tsv << "5\t1\t1\t1\t1\t2\t1\t1\t1\t1\t10\t\xFF\n".b
    responses = {
      [27, :left, :color, 6] => dirty_tsv
    }

    with_fake_tools(responses: responses) do
      labels = PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27],
        total_pages: 290,
        known_labels: { 26 => "23" }
      )

      assert_equal({ 27 => "24" }, labels)
    end
  end

  def test_limits_tesseract_openmp_threads
    environments = []
    responses = {
      [27, :left, :color, 6] => tsv("24", left: 100)
    }

    with_fake_tools(responses: responses, environments: environments) do
      PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27],
        total_pages: 290,
        known_labels: { 26 => "23" }
      )
    end

    refute_empty environments
    environments.each do |env|
      assert_equal "1", env["OMP_THREAD_LIMIT"]
      assert_equal "1", env["OMP_NUM_THREADS"]
    end
  end


  def test_reports_progress_for_each_visual_page_inspected
    updates = []

    with_fake_tools(responses: {}) do
      PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27, 28, 29],
        total_pages: 290,
        progress: ->(**payload) { updates << payload }
      )
    end

    assert_equal [0, 1, 2, 3, 4, 5], updates.map { |update| update.fetch(:current) }
    assert_equal [5], updates.map { |update| update.fetch(:total_pages) }.uniq
  end

  def test_returns_empty_mapping_when_pdf_geometry_cannot_be_read
    status = FakeStatus.new(false)
    Open3.stub(:capture3, ["", "broken pdf", status]) do
      assert_equal({}, PdfToLlmMd::VisualPageNumbers.extract(
        input: "/tmp/book.pdf",
        pages: [27],
        total_pages: 290
      ))
    end
  end

  private

  def with_fake_tools(responses:, commands: nil, environments: nil)
    mutex = Mutex.new
    capture3 = lambda do |*args|
      env = args.first.is_a?(Hash) ? args.shift : nil
      command = args
      mutex.synchronize do
        commands << command.dup if commands
        environments << env.dup if environments && env
      end

      case command.first
      when "pdfinfo"
        [pdfinfo_output(26..30), "", FakeStatus.new(true)]
      when "pdftoppm"
        prefix = command.last
        FileUtils.mkdir_p(File.dirname(prefix))
        File.write("#{prefix}.png", "fake image")
        ["", "", FakeStatus.new(true)]
      when "tesseract"
        image_path = command[1]
        page, side, variant = File.basename(image_path).match(
          /page-(\d+)-(left|right)-(color|gray)\.png\z/
        ).captures
        psm = command.fetch(command.index("--psm") + 1).to_i
        payload = responses.fetch(
          [page.to_i, side.to_sym, variant.to_sym, psm],
          tsv_header
        )
        [payload, "", FakeStatus.new(true)]
      else
        raise "Unexpected command: #{command.inspect}"
      end
    end

    Open3.stub(:capture3, capture3) { yield }
  end

  def pdfinfo_output(pages)
    pages.map { |page| "Page %4d size:  612 x 792 pts" % page }.join("\n") + "\n"
  end

  def tsv(text, left:, top: 430, width: 45, height: 30, confidence: 90.0)
    tsv_header + [
      5, 1, 1, 1, 1, 1, left, top, width, height, confidence, text
    ].join("\t") + "\n"
  end

  def tsv_header
    "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
  end
end
