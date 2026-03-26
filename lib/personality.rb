# frozen_string_literal: true

module Personality
  class Error < StandardError; end
end

require_relative "personality/version"
require_relative "personality/db"
require_relative "personality/embedding"
require_relative "personality/chunker"
require_relative "personality/hooks"
require_relative "personality/context"
require_relative "personality/cart"
require_relative "personality/memory"
require_relative "personality/tts"
require_relative "personality/indexer"
require_relative "personality/cli"
