# frozen_string_literal: true

require "zip" unless defined?(Zip)
require "yaml"
require "fileutils"

module Personality
  # Identity configuration from preferences
  IdentityConfig = Struct.new(:agent, :name, :full_name, :version, :type, :source, :tagline, keyword_init: true) do
    def self.from_hash(h)
      h ||= {}
      new(
        agent: h["agent"].to_s,
        name: h["name"].to_s,
        full_name: h["full_name"].to_s,
        version: h["version"].to_s,
        type: h["type"].to_s,
        source: h["source"].to_s,
        tagline: h["tagline"].to_s
      )
    end

    def to_hash
      members.each_with_object({}) { |k, h| v = self[k]; h[k.to_s] = v unless v.nil? || v.empty? }
    end
  end

  # TTS configuration
  TTSConfig = Struct.new(:enabled, :voice, keyword_init: true) do
    def self.from_hash(h)
      h ||= {}
      new(enabled: h.fetch("enabled", true), voice: h.fetch("voice", "").to_s)
    end

    def to_hash
      {"enabled" => enabled, "voice" => voice}
    end
  end

  # Preferences config (identity + tts + extras)
  PreferencesConfig = Struct.new(:identity, :tts, :extra, keyword_init: true) do
    def self.from_hash(data)
      data ||= {}
      known = %w[identity tts]
      extra = data.reject { |k, _| known.include?(k) }
      new(
        identity: IdentityConfig.from_hash(data["identity"]),
        tts: TTSConfig.from_hash(data["tts"]),
        extra: extra
      )
    end

    def to_hash
      h = {}
      id_h = identity.to_hash
      h["identity"] = id_h unless id_h.empty?
      h["tts"] = tts.to_hash if tts.enabled || !tts.voice.empty?
      h.merge(extra || {})
    end
  end

  # A loaded cartridge
  Cartridge = Struct.new(:path, :tag, :version, :memories, :preferences, :created_at, keyword_init: true) do
    def name
      n = preferences&.identity&.name
      (n.nil? || n.empty?) ? tag : n
    end

    def voice
      preferences&.tts&.voice
    end

    def memory_count
      memories&.size || 0
    end
  end

  # Manages .pcart (personality cartridge) ZIP files.
  #
  # A .pcart file is a ZIP archive containing:
  #   persona.yml      - tag, version, and memories array
  #   preferences.yml  - identity metadata and TTS settings
  #
  class CartManager
    EXTENSION = ".pcart"

    def initialize(carts_dir: nil, training_dir: nil)
      @carts_dir = carts_dir || File.join(Dir.home, ".local", "share", "personality", "carts")
      @training_dir = training_dir
    end

    attr_reader :carts_dir, :training_dir

    # Load a cartridge from a .pcart file.
    #
    # @param path [String] Path to the .pcart file
    # @return [Cartridge]
    def load_cart(path)
      raise Errno::ENOENT, "Cart file not found: #{path}" unless File.exist?(path)

      require "zip"
      Zip::File.open(path) do |zf|
        # persona.yml is required
        persona_entry = zf.find_entry("persona.yml")
        raise ArgumentError, "Missing persona.yml in cart" unless persona_entry

        persona_data = YAML.safe_load(persona_entry.get_input_stream.read, permitted_classes: [Date, Time]) || {}

        tag = persona_data.fetch("tag", File.basename(path, EXTENSION))
        version = persona_data.fetch("version", "").to_s

        memories = parse_memories(persona_data.fetch("memories", []))

        # preferences.yml is optional
        prefs_data = {}
        prefs_entry = zf.find_entry("preferences.yml")
        if prefs_entry
          prefs_data = YAML.safe_load(prefs_entry.get_input_stream.read, permitted_classes: [Date, Time]) || {}
        end

        # Also check persona.yml for embedded preferences (training format)
        if persona_data.key?("preferences")
          base_prefs = persona_data["preferences"]
          base_prefs.each { |k, v| prefs_data[k] = v unless prefs_data.key?(k) } if base_prefs.is_a?(Hash)
        end

        preferences = PreferencesConfig.from_hash(prefs_data)

        Cartridge.new(
          path: path,
          tag: tag,
          version: version,
          memories: memories,
          preferences: preferences
        )
      end
    end

    # Save a cartridge to a .pcart file.
    #
    # @param cart [Cartridge] The cartridge to save
    # @param path [String, nil] Output path (defaults to carts_dir/tag.pcart)
    # @return [String] Path to the saved file
    def save_cart(cart, path: nil)
      path ||= begin
        FileUtils.mkdir_p(@carts_dir)
        File.join(@carts_dir, "#{cart.tag}#{EXTENSION}")
      end

      FileUtils.mkdir_p(File.dirname(path))

      persona_yaml = YAML.dump({
        "tag" => cart.tag,
        "version" => cart.version,
        "memories" => cart.memories.map { |m| {"subject" => m.subject, "content" => m.content} }
      })

      prefs_yaml = YAML.dump(cart.preferences.to_hash)

      require "zip"
      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(persona_yaml)
        zos.put_next_entry("preferences.yml")
        zos.write(prefs_yaml)
      end

      path
    end

    # Create a cartridge from a training YAML file.
    #
    # @param training_path [String] Path to the training file
    # @param output_path [String, nil] Output path for the .pcart file
    # @return [Cartridge]
    def create_from_training(training_path, output_path: nil)
      require_relative "training_parser"

      parser = TrainingParser.new
      doc = parser.parse_file(training_path)

      tag = doc.tag.empty? ? File.basename(training_path, ".*").downcase : doc.tag
      preferences = PreferencesConfig.from_hash(doc.preferences)

      cart = Cartridge.new(
        path: nil,
        tag: tag,
        version: doc.version,
        memories: doc.memories,
        preferences: preferences,
        created_at: Time.now.utc.to_s
      )

      saved_path = save_cart(cart, path: output_path)
      cart.path = saved_path
      cart
    end

    # Import a cart's memories into the database.
    #
    # @param cart [Cartridge] The cartridge to import
    # @return [Hash] Import result with counts
    def import_memories(cart)
      require_relative "db"
      require_relative "cart"
      require_relative "memory"

      DB.migrate!

      # Ensure cart exists in DB with full identity
      db_cart = Cart.create(
        cart.tag,
        name: cart.preferences.identity.name,
        type: cart.preferences.identity.type,
        tagline: cart.preferences.identity.tagline
      )

      # Update fields that create doesn't set
      db = DB.connection
      db.execute(
        "UPDATE carts SET version = ?, source = ?, name = COALESCE(NULLIF(?, ''), name), type = COALESCE(NULLIF(?, ''), type), tagline = COALESCE(NULLIF(?, ''), tagline) WHERE id = ?",
        [cart.version, cart.preferences.identity.source, cart.preferences.identity.name, cart.preferences.identity.type, cart.preferences.identity.tagline, db_cart[:id]]
      )

      mem = Memory.new
      stored = 0
      skipped = 0

      cart.memories.each do |training_mem|
        # Check for existing memory with same subject
        existing = db.execute(
          "SELECT id FROM memories WHERE cart_id = ? AND subject = ?",
          [db_cart[:id], training_mem.subject]
        ).first

        if existing
          skipped += 1
        else
          mem.store(subject: training_mem.subject, content: training_mem.content)
          stored += 1
        end
      end

      {stored: stored, skipped: skipped, total: cart.memory_count, cart_id: db_cart[:id]}
    end

    # List available .pcart files.
    #
    # @return [Array<String>] Sorted list of cart file paths
    def list_carts
      return [] unless Dir.exist?(@carts_dir)
      Dir.glob(File.join(@carts_dir, "*#{EXTENSION}")).sort
    end

    # Get quick info about a cart without fully loading it.
    #
    # @param path [String] Path to the cart file
    # @return [Hash]
    def cart_info(path)
      require "zip"
      Zip::File.open(path) do |zf|
        entry = zf.find_entry("persona.yml")
        return {error: "Missing persona.yml"} unless entry

        data = YAML.safe_load(entry.get_input_stream.read, permitted_classes: [Date, Time]) || {}
        {
          tag: data.fetch("tag", File.basename(path, EXTENSION)),
          version: data.fetch("version", "").to_s,
          memory_count: Array(data.fetch("memories", [])).size
        }
      end
    rescue => e
      {error: e.message}
    end

    private

    def parse_memories(list)
      return [] unless list.is_a?(Array)

      list.filter_map do |item|
        next unless item.is_a?(Hash) && item["subject"] && item["content"]
        content = item["content"]
        content = content.map(&:to_s).join(", ") if content.is_a?(Array)
        TrainingMemory.new(subject: item["subject"].to_s, content: content.to_s)
      end
    end
  end
end
