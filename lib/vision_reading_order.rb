# frozen_string_literal: true

module PdfToLlmMd
  class VisionReadingOrder
    Observation = Struct.new(
      :confidence,
      :x,
      :y,
      :width,
      :height,
      :text,
      keyword_init: true
    ) do
      def cx
        x + (width / 2.0)
      end

      def cy
        y + (height / 2.0)
      end
    end

    Result = Struct.new(:markdown, :diagnostics, keyword_init: true)
    ClusterResult = Struct.new(:centers, :sse, :mass_ratios, keyword_init: true)

    DEFAULTS = {
      "max_columns" => 3,
      "edge_bleed_fraction" => 0.025,
      "candidate_max_width" => 0.65,
      "candidate_max_height" => 0.15,
      "minimum_alpha_characters" => 3,
      "minimum_split_improvement" => 0.55,
      "minimum_column_gap" => 0.16,
      "minimum_cluster_weight_ratio" => 0.15,
      "map_noise_max_characters" => 4,
      "map_noise_column_distance" => 0.11,
      "paragraph_vertical_gap" => 0.028,
      "table_row_y_tolerance" => 0.015,
      "table_min_cells_per_row" => 4,
      "table_min_rows" => 4,
      "table_min_row_span" => 0.45,
      "table_cell_max_width" => 0.28,
      "table_cell_max_characters" => 20,
      "table_min_short_cell_ratio" => 0.60,
      "table_min_page_compact_ratio" => 0.80,
      "table_min_row_ratio" => 0.20
    }.freeze

    MAPLIKE = /\A[\s\d°•.xX+*×\-()]+\z/
    HEADING = /\A(?:\d+\.|Doors\s*&\s*Traps\b|Actions\b|Bonus Actions\b|Reactions\b|Ring of\b)/i

    def initialize(config:)
      @config = DEFAULTS.merge(config.fetch("vision", {}))
    end

    def load_tsv(path)
      File.foreach(path, encoding: "UTF-8").with_index.filter_map do |line, index|
        next if index.zero?

        fields = line.chomp.split("\t", 6)
        next unless fields.length == 6

        confidence, x, y, width, height, text = fields
        text = text.to_s.strip
        next if text.empty?

        Observation.new(
          confidence: Float(confidence),
          x: Float(x),
          y: Float(y),
          width: Float(width),
          height: Float(height),
          text: text
        )
      end
    end

    def render(observations)
      edge_dropped, body = observations.partition { |observation| edge_bleed?(observation) }
      body = observations.dup if body.empty?

      recognized_characters = observation_characters(body)
      table = table_geometry(body)
      cluster = infer_columns(body)
      centers = cluster.centers

      map_dropped, body = body.partition do |observation|
        map_noise?(observation, centers)
      end

      columns = Array.new(centers.length) { [] }
      body.each do |observation|
        index = nearest_center(observation.cx, centers)
        columns[index] << observation
      end

      lines = [
        "<!-- APPLE VISION columns=#{centers.length} " \
          "edge_dropped=#{edge_dropped.length} map_noise_dropped=#{map_dropped.length} " \
          "table_like=#{table.fetch("table_like")} -->"
      ]

      columns.each_with_index do |column, index|
        lines << ""
        lines << format(
          "<!-- VISION REGION %d center=%.3f -->",
          index + 1,
          centers[index]
        )
        lines.concat(render_column(column))
      end

      markdown = lines.join("\n").rstrip + "\n"
      diagnostics = {
        "columns" => centers.length,
        "centers" => centers.map { |center| center.round(4) },
        "input_observations" => observations.length,
        "kept_observations" => body.length,
        "input_characters" => observation_characters(observations),
        "recognized_characters" => recognized_characters,
        "kept_characters" => observation_characters(body),
        "edge_dropped" => edge_dropped.length,
        "map_noise_dropped" => map_dropped.length
      }.merge(table)

      Result.new(markdown: markdown, diagnostics: diagnostics.freeze)
    end

    private

    def edge_bleed?(observation)
      margin = config_float("edge_bleed_fraction")
      observation.x < margin || (observation.x + observation.width) > (1.0 - margin)
    end

    def infer_columns(observations)
      maximum = config_integer("max_columns").clamp(1, 3)
      chosen = kmeans(observations, 1)
      return ClusterResult.new(centers: [0.5], sse: 0.0, mass_ratios: [1.0]) unless chosen

      previous_sse = chosen.sse

      (2..maximum).each do |count|
        candidate = kmeans(observations, count)
        break unless candidate
        break unless split_acceptable?(candidate, previous_sse)

        chosen = candidate
        previous_sse = candidate.sse
      end

      chosen
    end

    def kmeans(observations, count)
      candidates = observations.select { |observation| column_candidate?(observation) }
      return nil if candidates.length < count

      values = candidates.map(&:cx)
      weights = candidates.map { |observation| observation_weight(observation) }
      sorted = values.sort
      centers = Array.new(count) do |index|
        position = (((index + 0.5) * sorted.length) / count).floor
        sorted[[position, sorted.length - 1].min]
      end.sort

      assignments = nil

      100.times do
        assignments = values.map { |value| nearest_center(value, centers) }
        new_centers = Array.new(count) do |index|
          members = values.each_index.select { |member| assignments[member] == index }
          if members.empty?
            centers[index]
          else
            total_weight = members.sum { |member| weights[member] }
            members.sum { |member| values[member] * weights[member] } / total_weight
          end
        end.sort

        delta = centers.zip(new_centers).map { |left, right| (left - right).abs }.max
        centers = new_centers
        break if delta < 0.000001
      end

      assignments = values.map { |value| nearest_center(value, centers) }
      sse = values.each_index.sum do |index|
        weights[index] * ((values[index] - centers[assignments[index]])**2)
      end
      total_weight = weights.sum
      mass_ratios = Array.new(count) do |index|
        members = weights.each_index.select { |member| assignments[member] == index }
        members.sum { |member| weights[member] } / total_weight
      end

      ClusterResult.new(
        centers: centers.freeze,
        sse: sse,
        mass_ratios: mass_ratios.freeze
      )
    end

    def split_acceptable?(candidate, previous_sse)
      return false if previous_sse <= 0.0

      improvement = (previous_sse - candidate.sse) / previous_sse
      minimum_gap = candidate.centers.each_cons(2).map { |left, right| right - left }.min
      minimum_mass = candidate.mass_ratios.min

      improvement >= config_float("minimum_split_improvement") &&
        minimum_gap >= config_float("minimum_column_gap") &&
        minimum_mass >= config_float("minimum_cluster_weight_ratio")
    end

    def column_candidate?(observation)
      alpha_count = observation.text.count("A-Za-z")
      alpha_count >= config_integer("minimum_alpha_characters") &&
        observation.width <= config_float("candidate_max_width") &&
        observation.height <= config_float("candidate_max_height")
    end

    def observation_weight(observation)
      [[observation.text.length, 5].max, 100].min.to_f
    end

    def map_noise?(observation, centers)
      text = observation.text.strip
      return false if text.length > config_integer("map_noise_max_characters")
      return false unless MAPLIKE.match?(text)

      centers.map { |center| (observation.cx - center).abs }.min >
        config_float("map_noise_column_distance")
    end

    def table_geometry(observations)
      rows = []
      tolerance = config_float("table_row_y_tolerance")

      observations.sort_by { |observation| -observation.cy }.each do |observation|
        row = rows.find { |candidate| (candidate[:cy] - observation.cy).abs <= tolerance }

        if row
          count = row[:observations].length
          row[:cy] = ((row[:cy] * count) + observation.cy) / (count + 1)
          row[:observations] << observation
        else
          rows << { cy: observation.cy, observations: [observation] }
        end
      end

      qualifying_rows = rows.count do |row|
        cells = row.fetch(:observations)
        next false if cells.length < config_integer("table_min_cells_per_row")

        left = cells.map(&:x).min
        right = cells.map { |cell| cell.x + cell.width }.max
        span = right - left
        short_ratio = cells.count { |cell| compact_table_cell?(cell) }.fdiv(cells.length)

        span >= config_float("table_min_row_span") &&
          short_ratio >= config_float("table_min_short_cell_ratio")
      end

      row_ratio = rows.empty? ? 0.0 : qualifying_rows.fdiv(rows.length)
      page_compact_ratio = observations.empty? ? 0.0 :
        observations.count { |observation| compact_table_cell?(observation) }.fdiv(observations.length)
      table_like = qualifying_rows >= config_integer("table_min_rows") &&
        row_ratio >= config_float("table_min_row_ratio") &&
        page_compact_ratio >= config_float("table_min_page_compact_ratio")

      {
        "table_like" => table_like,
        "table_rows" => qualifying_rows,
        "table_row_ratio" => row_ratio.round(4),
        "table_page_compact_ratio" => page_compact_ratio.round(4)
      }
    end

    def compact_table_cell?(observation)
      observation.width <= config_float("table_cell_max_width") &&
        observation_character_count(observation) <= config_integer("table_cell_max_characters")
    end

    def observation_character_count(observation)
      observation.text.scan(/[[:alnum:]]/).length
    end

    def observation_characters(observations)
      observations.sum { |observation| observation_character_count(observation) }
    end

    def render_column(column)
      lines = []
      previous = nil

      ordered(column).each do |observation|
        if previous
          vertical_gap = previous.cy - observation.cy
          if vertical_gap > config_float("paragraph_vertical_gap") || HEADING.match?(observation.text)
            lines << "" unless lines.empty? || lines.last.empty?
          end
        end

        lines << observation.text
        previous = observation
      end

      lines
    end

    def ordered(observations)
      observations.sort_by { |observation| [-observation.cy, observation.x] }
    end

    def nearest_center(value, centers)
      centers.each_index.min_by { |index| (value - centers[index]).abs }
    end

    def config_float(key)
      Float(@config.fetch(key))
    end

    def config_integer(key)
      Integer(@config.fetch(key))
    end
  end
end
