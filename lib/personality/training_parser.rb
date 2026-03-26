# frozen_string_literal: true

require "yaml"
require "json"

module Personality
  # Parsed training memory
  TrainingMemory = Struct.new(:subject, :content, keyword_init: true)

  # Parsed training document
  TrainingDocument = Struct.new(:source, :format, :tag, :version, :memories, :preferences, keyword_init: true) do
    def count
      memories.size
    end
  end

  # Parses YAML and JSON training files to extract persona memories.
  #
  # Training files define a persona's identity, traits, speech patterns,
  # protocols, and other memories using a dot-notation subject taxonomy:
  #
  #   self.identity.*    - Core self-definition
  #   self.trait.*       - Personality characteristics
  #   self.protocol.*    - Rules of behavior
  #   self.speech.*      - Communication patterns
  #   self.quote.*       - Iconic lines
  #   user.identity.*    - How to address the user
  #   meta.system.*      - Meta configuration
  #
  class TrainingParser
    SUPPORTED_EXTENSIONS = %w[.yml .yaml .json .jsonld].freeze

    # Parse a training file into a TrainingDocument.
    #
    # @param path [String] Path to the training file
    # @return [TrainingDocument]
    # @raise [ArgumentError] if file format is unsupported
    # @raise [Errno::ENOENT] if file doesn't exist
    def parse_file(path)
      path = File.expand_path(path)
      raise Errno::ENOENT, "Training file not found: #{path}" unless File.exist?(path)

      ext = File.extname(path).downcase
      content = File.read(path, encoding: "utf-8")

      tag, version, memories, preferences = case ext
        when ".yml", ".yaml" then parse_yaml(content)
        when ".json", ".jsonld" then parse_json(content)
        else raise ArgumentError, "Unsupported file format: #{ext}"
        end

      TrainingDocument.new(
        source: path,
        format: ext.delete_prefix("."),
        tag: tag,
        version: version,
        memories: memories,
        preferences: preferences
      )
    end

    # List training files in a directory.
    #
    # @param directory [String] Directory to scan
    # @return [Array<String>] Sorted list of training file paths
    def list_files(directory)
      return [] unless Dir.exist?(directory)

      Dir.glob(File.join(directory, "*.{yml,yaml,json,jsonld}"))
        .sort_by { |p| File.basename(p).downcase }
    end

    # Validate a training file.
    #
    # @param path [String] Path to the training file
    # @return [Array(Boolean, String)] [valid?, message]
    def validate(path)
      doc = parse_file(path)
      if doc.count == 0
        [false, "No memories found in file"]
      else
        [true, "Valid: #{doc.count} memories, tag=#{doc.tag}"]
      end
    rescue => e
      [false, e.message]
    end

    private

    def parse_yaml(content)
      data = YAML.safe_load(content, permitted_classes: [Date, Time])
      raise ArgumentError, "YAML root must be a hash" unless data.is_a?(Hash)

      tag = data.fetch("tag", "").to_s
      version = data.fetch("version", "").to_s
      preferences = data.fetch("preferences", {})
      preferences = {} unless preferences.is_a?(Hash)

      memories = []

      # Legacy identity section
      identity = data.fetch("identity", {})
      if identity.is_a?(Hash)
        identity.each do |key, value|
          memories << TrainingMemory.new(subject: "identity.#{key}", content: value.to_s) if value
        end
      end

      # Memories section
      parse_memory_list(data.fetch("memories", []), memories)

      [tag, version, memories, preferences]
    end

    def parse_json(content)
      data = JSON.parse(content)
      raise ArgumentError, "JSON root must be an object" unless data.is_a?(Hash)

      tag = data.fetch("tag", "").to_s
      version = data.fetch("version", "").to_s
      preferences = data.fetch("preferences", {})
      preferences = {} unless preferences.is_a?(Hash)

      memories = []

      # Top-level identity fields
      %w[name description personality purpose].each do |key|
        value = data[key]
        memories << TrainingMemory.new(subject: "identity.#{key}", content: value) if value.is_a?(String)
      end

      # Memories array
      parse_memory_list(data.fetch("memories", []), memories)

      # Knowledge graph
      knowledge = data.fetch("knowledge", [])
      if knowledge.is_a?(Array)
        knowledge.each do |item|
          next unless item.is_a?(Hash)
          subject = item.fetch("@type", "knowledge.general").to_s
          mem_content = (item["description"] || item["value"]).to_s
          memories << TrainingMemory.new(subject: subject, content: mem_content) unless mem_content.empty?
        end
      end

      [tag, version, memories, preferences]
    end

    def parse_memory_list(list, memories)
      return unless list.is_a?(Array)

      list.each do |item|
        next unless item.is_a?(Hash)
        subject = item["subject"].to_s
        content = item["content"]
        next if subject.empty? || content.nil?

        # Handle list content (e.g., addressed_as: [Pilot, Pilot Cooper])
        content = content.map(&:to_s).join(", ") if content.is_a?(Array)
        content = content.to_s
        next if content.empty?

        memories << TrainingMemory.new(subject: subject, content: content)
      end
    end
  end
end
