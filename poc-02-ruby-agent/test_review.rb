# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'review'

class ReviewPocTest < Minitest::Test
  def setup
    @fixtures = JSON.parse(File.read(File.join(__dir__, 'fixtures.json')))
    @schema = JSON.parse(File.read(File.join(__dir__, 'schema.json')))
    @fixture = @fixtures.fetch('clean')
    @source = ReviewPoc::Source.new(@fixture)
    @review = {'summary' => '問題なし', 'findings' => []}
  end

  def test_clean_output_requires_actual_tool_use
    assert_raises(ReviewPoc::InvalidReview) { validate }
    @source.read
    assert_equal @review, validate
  end

  def test_failed_tool_cannot_turn_into_a_clean_review
    @source = ReviewPoc::Source.new(@fixture, fail: true)
    assert_raises(IOError) { @source.read }
    assert_raises(ReviewPoc::InvalidReview) { validate }
  end

  def test_malformed_and_invalid_location_are_rejected
    @source.read
    @review = {'summary' => '問題なし'}
    assert_raises(ReviewPoc::InvalidReview) { validate }
    @review = {'summary' => '問題', 'findings' => [{'path' => 'other.rb', 'line' => 1, 'body' => 'bug'}]}
    assert_raises(ReviewPoc::InvalidReview) { validate }
    @review['findings'][0].merge!('path' => 'average.rb', 'line' => 999)
    assert_raises(ReviewPoc::InvalidReview) { validate }
  end

  private

  def validate
    ReviewPoc.validate!(@review, @source, @fixture, @schema)
  end
end
