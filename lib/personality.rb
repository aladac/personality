# frozen_string_literal: true

module Personality
  class Error < StandardError; end
end

require_relative "personality/version"
require_relative "personality/db"
require_relative "personality/embedding"
require_relative "personality/chunker"
require_relative "personality/cli"
