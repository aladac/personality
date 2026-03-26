# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Personality
  module Embedding
    DEFAULT_URL = "http://localhost:11434"
    DEFAULT_MODEL = "nomic-embed-text"
    MAX_INPUT_LENGTH = 8000
    DIMENSIONS = 768

    class Error < Personality::Error; end

    class << self
      def generate(text, model: nil, url: nil)
        truncated = text.to_s[0, MAX_INPUT_LENGTH]
        return [] if truncated.empty?

        ollama_url = url || ENV.fetch("OLLAMA_URL", DEFAULT_URL)
        ollama_model = model || ENV.fetch("OLLAMA_MODEL", DEFAULT_MODEL)

        uri = URI.join(ollama_url, "/api/embeddings")
        body = {model: ollama_model, prompt: truncated}.to_json

        response = Net::HTTP.post(uri, body, "Content-Type" => "application/json")

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "Ollama returned #{response.code}: #{response.body}"
        end

        result = JSON.parse(response.body)
        embedding = result["embedding"]

        unless embedding.is_a?(Array) && !embedding.empty?
          raise Error, "Unexpected Ollama response: missing embedding"
        end

        embedding
      end
    end
  end
end
