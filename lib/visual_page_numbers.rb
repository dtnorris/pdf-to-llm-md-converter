# frozen_string_literal: true

require "open3"
require "tmpdir"

module PdfToLlmMd
  class VisualPageNumbers
    DPI = 300
    BOTTOM_BAND_RATIO = 0.16
    SIDE_WIDTH_RATIO = 0.30
    MIN_CONFIDENCE = 65.0
    MIN_VERTICAL_CENTER_RATIO = 0.65
    OUTER_HORIZONTAL_RATIO = 0.40
    MAX_DIGITS = 4
    OCR_PAGE_SEGMENTATION_MODES = [6, 11].freeze
    RASTER_VARIANTS = {
      color: ["-png"].freeze,
      gray: ["-gray", "-png"].freeze
    }.freeze
    WORKER_COUNT = 2

    def self.extract(input:, pages:, total_pages:, known_labels: {}, progress: nil)
      new(input: input, total_pages: total_pages).numbers_for(
        pages,
        known_labels: known_labels,
        progress: progress
      )
    end

    def initialize(input:, total_pages:)
      @input = File.expand_path(input)
      @total_pages = Integer(total_pages)
      raise ArgumentError, "total_pages must be positive" unless @total_pages.positive?
    end

    def numbers_for(pages, known_labels: {}, progress: nil)
      requested_pages = Array(pages).map { |page| validate_page!(page) }.uniq.sort
      return {}.freeze if requested_pages.empty?

      known_numeric = numeric_known_labels(known_labels)
      inspection_pages = requested_pages.flat_map do |page|
        [page - 1, page, page + 1]
      end.select { |page| page.between?(1, @total_pages) }.uniq.sort

      pages_to_ocr = inspection_pages.reject { |page| known_numeric.key?(page) }
      geometries = load_page_geometries(pages_to_ocr)
      visual_candidates = detect_candidates(
        pages_to_ocr,
        geometries,
        progress: progress
      )

      candidates = known_numeric.transform_values { |value| [value].freeze }.merge(visual_candidates)

      requested_pages.each_with_object({}) do |physical_page, labels|
        supported = candidates.fetch(physical_page, []).select do |candidate|
          sequence_supported?(physical_page, candidate, candidates)
        end
        next unless supported.one?

        labels[physical_page] = supported.first.to_s
      end.freeze
    end

    private

    def numeric_known_labels(labels)
      labels.each_with_object({}) do |(page, label), result|
        next unless page.is_a?(Integer) && page.between?(1, @total_pages)

        text = label.to_s.strip
        next unless text.match?(/\A[1-9]\d{0,#{MAX_DIGITS - 1}}\z/)

        value = Integer(text, 10)
        next if value > @total_pages

        result[page] = value
      end.freeze
    end

    def load_page_geometries(pages)
      return {}.freeze if pages.empty?

      stdout, _stderr, status = Open3.capture3(
        "pdfinfo",
        "-f", pages.min.to_s,
        "-l", pages.max.to_s,
        "-box",
        @input
      )
      return {}.freeze unless status.success?

      sizes = {}
      stdout.each_line do |line|
        match = line.match(/^Page\s+(\d+)\s+size:\s+([0-9.]+)\s+x\s+([0-9.]+)\s+pts\s*$/)
        next unless match

        page = Integer(match[1], 10)
        next unless pages.include?(page)

        width = Float(match[2])
        height = Float(match[3])
        next unless width.positive? && height.positive?

        sizes[page] = { width: width, height: height }.freeze
      end
      sizes.freeze
    rescue Errno::ENOENT, ArgumentError
      {}.freeze
    end

    def detect_candidates(pages, geometries, progress: nil)
      pages = pages.select { |page| geometries.key?(page) }
      return {}.freeze if pages.empty?

      progress&.call(current: 0, total_pages: pages.length)

      queue = Queue.new
      pages.each { |page| queue << page }
      results = {}
      completed = 0
      mutex = Mutex.new
      worker_count = [WORKER_COUNT, pages.length].min

      Dir.mktmpdir("pdf-visible-page-numbers-") do |tmpdir|
        workers = worker_count.times.map do
          Thread.new do
            loop do
              page = queue.pop(true)
              candidates = candidates_for_page(page, geometries.fetch(page), tmpdir)
              mutex.synchronize do
                results[page] = candidates
                completed += 1
                progress&.call(
                  current: completed,
                  total_pages: pages.length
                )
              end
            rescue ThreadError
              break
            end
          end
        end
        workers.each(&:join)
      end

      results.transform_values { |values| values.uniq.sort.freeze }.freeze
    end

    def candidates_for_page(page, geometry, tmpdir)
      crop = crop_geometry(geometry)
      candidates = []

      [:left, :right].each do |side|
        side_candidates = candidates_for_side(page, side, crop, tmpdir)
        candidates.concat(side_candidates)
      end

      candidates.uniq.freeze
    rescue Errno::ENOENT
      [].freeze
    end

    def candidates_for_side(page, side, crop, tmpdir)
      RASTER_VARIANTS.each do |variant, raster_flags|
        image_path = render_corner(page, side, variant, raster_flags, crop, tmpdir)
        next unless image_path

        OCR_PAGE_SEGMENTATION_MODES.each do |psm|
          candidates = ocr_candidates(
            image_path,
            side: side,
            crop_width: crop.fetch(:side_width),
            crop_height: crop.fetch(:band_height),
            psm: psm
          )
          return candidates unless candidates.empty?
        end
      end

      [].freeze
    end

    def crop_geometry(geometry)
      page_width = (geometry.fetch(:width) * DPI / 72.0).round
      page_height = (geometry.fetch(:height) * DPI / 72.0).round
      band_y = (page_height * (1.0 - BOTTOM_BAND_RATIO)).round
      band_height = page_height - band_y
      side_width = (page_width * SIDE_WIDTH_RATIO).round

      {
        page_width: page_width,
        band_y: band_y,
        band_height: band_height,
        side_width: side_width
      }.freeze
    end

    def render_corner(page, side, variant, raster_flags, crop, tmpdir)
      x = side == :left ? 0 : crop.fetch(:page_width) - crop.fetch(:side_width)
      prefix = File.join(tmpdir, "page-#{page}-#{side}-#{variant}")
      command = [
        "pdftoppm",
        "-f", page.to_s,
        "-l", page.to_s,
        "-singlefile",
        "-r", DPI.to_s,
        "-cropbox",
        "-x", x.to_s,
        "-y", crop.fetch(:band_y).to_s,
        "-W", crop.fetch(:side_width).to_s,
        "-H", crop.fetch(:band_height).to_s,
        *raster_flags,
        @input,
        prefix
      ]

      _stdout, _stderr, status = Open3.capture3(*command)
      return nil unless status.success?

      path = "#{prefix}.png"
      File.file?(path) ? path : nil
    end

    def ocr_candidates(image_path, side:, crop_width:, crop_height:, psm:)
      env = {
        "OMP_THREAD_LIMIT" => "1",
        "OMP_NUM_THREADS" => "1"
      }
      stdout, _stderr, status = Open3.capture3(
        env,
        "tesseract",
        image_path,
        "stdout",
        "--psm", psm.to_s,
        "tsv"
      )
      return [].freeze unless status.success?

      sanitized = stdout.to_s.encode(
        "UTF-8",
        invalid: :replace,
        undef: :replace,
        replace: ""
      )

      sanitized.each_line.filter_map do |line|
        fields = line.chomp.split("\t", -1)
        next unless fields.length >= 12 && fields[0] == "5"

        text = fields[11].to_s.strip
        next unless text.match?(/\A[1-9]\d{0,#{MAX_DIGITS - 1}}\z/)

        confidence = Float(fields[10]) rescue nil
        next unless confidence && confidence >= MIN_CONFIDENCE

        left = Integer(fields[6], 10) rescue nil
        top = Integer(fields[7], 10) rescue nil
        width = Integer(fields[8], 10) rescue nil
        height = Integer(fields[9], 10) rescue nil
        next unless [left, top, width, height].all?

        center_x = left + (width / 2.0)
        center_y = top + (height / 2.0)
        next if center_y < crop_height * MIN_VERTICAL_CENTER_RATIO

        horizontally_plausible = if side == :left
          center_x <= crop_width * OUTER_HORIZONTAL_RATIO
        else
          center_x >= crop_width * (1.0 - OUTER_HORIZONTAL_RATIO)
        end
        next unless horizontally_plausible

        value = Integer(text, 10)
        next if value > @total_pages

        value
      end.uniq.freeze
    rescue Errno::ENOENT
      [].freeze
    end

    def sequence_supported?(physical_page, value, candidates)
      previous = candidates.fetch(physical_page - 1, [])
      following = candidates.fetch(physical_page + 1, [])

      previous.include?(value - 1) || following.include?(value + 1)
    end

    def validate_page!(page)
      unless page.is_a?(Integer) && page.positive? && page <= @total_pages
        raise ArgumentError, "page must be within 1–#{@total_pages}"
      end

      page
    end
  end
end
