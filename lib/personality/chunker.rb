# frozen_string_literal: true

module Personality
  module Chunker
    MIN_LENGTH = 10
    DEFAULT_SIZE = 2000
    DEFAULT_OVERLAP = 200

    class << self
      def split(text, size: DEFAULT_SIZE, overlap: DEFAULT_OVERLAP)
        return [] if text.nil? || text.length < MIN_LENGTH

        return [text] if text.length <= size

        chunks = []
        start = 0
        while start < text.length
          chunk = text[start, size]
          chunks << chunk
          start += size - overlap
        end

        chunks
      end
    end
  end
end
