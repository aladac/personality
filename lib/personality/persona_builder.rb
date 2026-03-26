# frozen_string_literal: true

module Personality
  # Builds LLM persona instructions from cartridge memories.
  #
  # Groups memories by their dot-notation subject taxonomy and formats
  # them into structured markdown that teaches the LLM its character.
  #
  class PersonaBuilder
    CATEGORY_TITLES = {
      "identity" => "Identity",
      "trait" => "Personality Traits",
      "belief" => "Beliefs & Values",
      "speech" => "Speech Patterns",
      "knowledge" => "Knowledge",
      "relationship" => "Relationships",
      "behavior" => "Behaviors",
      "emotion" => "Emotional Tendencies",
      "goal" => "Goals & Motivations",
      "memory" => "Background & Memories",
      "quirk" => "Quirks & Mannerisms",
      "protocol" => "Protocols",
      "capability" => "Capabilities",
      "logic" => "Logic & Reasoning",
      "quote" => "Iconic Quotes",
      "history" => "History & Backstory"
    }.freeze

    # Preferred display order for self.* sub-categories
    SECTION_ORDER = %w[
      identity trait protocol speech capability relationship
      quote logic belief behavior emotion goal memory quirk knowledge history
    ].freeze

    # Build full persona instructions from a cartridge.
    #
    # @param cart [Cartridge] Loaded cartridge with memories and preferences
    # @return [String] Formatted markdown instructions
    def self.build_instructions(cart)
      new.build_instructions(cart)
    end

    # @param cart [Cartridge]
    # @return [String]
    def build_instructions(cart)
      return "" if cart.memories.nil? || cart.memories.empty?

      groups = group_by_top_level(cart.memories)
      lines = []

      # Header
      lines << "## Your Character\n\n"
      identity = cart.preferences&.identity
      if identity && !identity.name.empty?
        lines << "You are **#{identity.name}**"
        lines << ", a #{identity.type}" unless identity.type.empty?
        lines << ".\n\n"
      elsif !cart.tag.to_s.empty?
        lines << "You are roleplaying as **#{cart.tag}**.\n\n"
      end

      lines << "> \"#{identity.tagline}\"\n\n" if identity && !identity.tagline.empty?

      lines << "Stay in character at all times. Use the personality traits, "
      lines << "speech patterns, and knowledge provided below.\n"

      # self.* memories (the bulk of persona definition)
      if groups.key?("self")
        lines.concat(format_self_memories(groups.delete("self")))
      end

      # user.* memories
      if groups.key?("user")
        lines << "\n### User Interaction\n\n"
        groups.delete("user").each { |m| lines << "- #{m.content}\n" }
      end

      # meta.* memories
      if groups.key?("meta")
        lines << "\n### Meta Information\n\n"
        groups.delete("meta").each { |m| lines << "- #{m.content}\n" }
      end

      # identity.* already covered in header
      groups.delete("identity")

      # Remaining groups
      groups.sort.each do |category, mems|
        title = CATEGORY_TITLES.fetch(category, category.capitalize)
        lines << "\n### #{title}\n\n"
        mems.each { |m| lines << "- #{m.content}\n" }
      end

      lines.join
    end

    # Build a greeting from the cart's greeting memory.
    #
    # @param cart [Cartridge]
    # @param user_name [String, nil]
    # @return [String]
    def build_greeting(cart, user_name: nil)
      template = cart.memories&.find { |m|
        m.subject.downcase.include?("greeting") || m.subject.downcase.include?("salutation")
      }&.content

      unless template
        name = cart.preferences&.identity&.name
        name = cart.tag if name.nil? || name.empty?
        return "Hello, I am #{name}."
      end

      greeting = template
        .gsub("{{USER_ID}}", user_name || "User")
        .gsub("{{user}}", user_name || "User")
        .gsub("{{TIME_GREETING}}", time_greeting)

      greeting
    end

    # Build a brief summary for display.
    #
    # @param cart [Cartridge]
    # @return [String]
    def build_summary(cart)
      parts = []
      identity = cart.preferences&.identity

      if identity && !identity.name.empty?
        parts << identity.name
      elsif !cart.tag.to_s.empty?
        parts << cart.tag
      end

      parts << "(#{identity.type})" if identity && !identity.type.empty?
      parts << "v#{cart.version}" if cart.version && !cart.version.empty?

      parts.empty? ? "Persona loaded" : parts.join(" ")
    end

    private

    def group_by_top_level(memories)
      groups = Hash.new { |h, k| h[k] = [] }
      memories.each do |mem|
        category = mem.subject.split(".").first || "other"
        groups[category] << mem
      end
      groups
    end

    def format_self_memories(memories)
      lines = []

      # Sub-group by second level (trait, belief, speech, etc.)
      sub_groups = Hash.new { |h, k| h[k] = [] }
      memories.each do |mem|
        parts = mem.subject.split(".")
        sub_cat = parts.length > 1 ? parts[1] : "general"
        sub_groups[sub_cat] << mem
      end

      # Ordered sections first
      seen = Set.new
      SECTION_ORDER.each do |sub_cat|
        next unless sub_groups.key?(sub_cat)
        title = CATEGORY_TITLES.fetch(sub_cat, sub_cat.capitalize)
        lines << "\n### #{title}\n\n"
        sub_groups[sub_cat].each { |m| lines << "- #{m.content}\n" }
        seen << sub_cat
      end

      # Remaining sub-categories
      sub_groups.sort.each do |sub_cat, mems|
        next if seen.include?(sub_cat)
        title = CATEGORY_TITLES.fetch(sub_cat, sub_cat.capitalize)
        lines << "\n### #{title}\n\n"
        mems.each { |m| lines << "- #{m.content}\n" }
      end

      lines
    end

    def time_greeting
      hour = Time.now.hour
      if hour < 12
        "Good morning"
      elsif hour < 17
        "Good afternoon"
      else
        "Good evening"
      end
    end
  end
end
