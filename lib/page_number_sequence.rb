# frozen_string_literal: true

module PdfToLlmMd
  class PageNumberSequence
    MINIMUM_DIRECT_RUN = 3
    MAX_PROPAGATION_DISTANCE = 3
    MAX_DIGITS = 4

    def self.infer(pages:, known_labels:, total_pages:)
      new(total_pages: total_pages).infer(
        pages: pages,
        known_labels: known_labels
      )
    end

    def initialize(total_pages:)
      @total_pages = Integer(total_pages)
      raise ArgumentError, "total_pages must be positive" unless @total_pages.positive?
    end

    def infer(pages:, known_labels:)
      requested_pages = Array(pages).map { |page| validate_page!(page) }.uniq.sort
      return {}.freeze if requested_pages.empty?

      requested = requested_pages.to_h { |page| [page, true] }
      labels = normalize_known_labels(known_labels)
      numeric_labels = numeric_labels(labels)
      proposals = Hash.new { |hash, page| hash[page] = [] }

      qualifying_runs(numeric_labels).each do |run|
        offset = numeric_labels.fetch(run.first) - run.first
        propose_from_edge(
          edge_page: run.first,
          direction: -1,
          offset: offset,
          requested: requested,
          labels: labels,
          proposals: proposals
        )
        propose_from_edge(
          edge_page: run.last,
          direction: 1,
          offset: offset,
          requested: requested,
          labels: labels,
          proposals: proposals
        )
      end

      proposals.each_with_object({}) do |(page, values), inferred|
        unique = values.uniq
        next unless unique.one?

        inferred[page] = unique.first.to_s
      end.freeze
    end

    private

    def normalize_known_labels(known_labels)
      known_labels.each_with_object({}) do |(page, label), result|
        next unless page.is_a?(Integer) && page.between?(1, @total_pages)

        result[page] = label.to_s.strip
      end.freeze
    end

    def numeric_labels(labels)
      labels.each_with_object({}) do |(page, label), result|
        next unless label.match?(/\A[1-9]\d{0,#{MAX_DIGITS - 1}}\z/)

        value = Integer(label, 10)
        next if value > @total_pages

        result[page] = value
      end.freeze
    end

    def qualifying_runs(numeric_labels)
      runs = []
      current = []

      numeric_labels.keys.sort.each do |page|
        if current.empty? || consecutive?(current.last, page, numeric_labels)
          current << page
        else
          runs << current.freeze if current.length >= MINIMUM_DIRECT_RUN
          current = [page]
        end
      end

      runs << current.freeze if current.length >= MINIMUM_DIRECT_RUN
      runs.freeze
    end

    def consecutive?(previous_page, page, numeric_labels)
      page == previous_page + 1 &&
        numeric_labels.fetch(page) == numeric_labels.fetch(previous_page) + 1
    end

    def propose_from_edge(edge_page:, direction:, offset:, requested:, labels:, proposals:)
      1.upto(MAX_PROPAGATION_DISTANCE) do |distance|
        page = edge_page + (direction * distance)
        break unless page.between?(1, @total_pages)
        break unless requested.key?(page)
        break if labels.key?(page)

        value = page + offset
        break unless value.between?(1, @total_pages)

        proposals[page] << value
      end
    end

    def validate_page!(page)
      unless page.is_a?(Integer) && page.between?(1, @total_pages)
        raise ArgumentError, "page must be within 1–#{@total_pages}"
      end

      page
    end
  end
end
