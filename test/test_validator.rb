# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/validator"

class ValidatorTest < Minitest::Test
  def setup
    @config = YAML.safe_load_file(File.expand_path("../config/conversion.yml", __dir__))
    @validator = PdfToLlmMd::Validator.new(config: @config)
  end

  def test_passes_complete_document
    markdown = "<!-- PDF Page 1 -->\n" + ("a" * 30) + "\n<!-- PDF Page 2 -->\n" + ("b" * 30)
    result = @validator.validate(markdown: markdown, expected_pages: [1, 2])

    assert result.valid
    assert_empty result.errors
  end

  def test_fails_missing_marker
    markdown = "<!-- PDF Page 1 -->\n" + ("a" * 30)
    result = @validator.validate(markdown: markdown, expected_pages: [1, 2])

    refute result.valid
    assert result.errors.any? { |error| error.include?("Missing page markers") }
  end
end
