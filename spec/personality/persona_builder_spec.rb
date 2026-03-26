# frozen_string_literal: true

require "personality"
require "personality/persona_builder"
require "personality/cart_manager"

RSpec.describe Personality::PersonaBuilder do
  let(:builder) { described_class.new }

  def make_cart(tag: "test", version: "1.0", memories: [], preferences: {})
    Personality::Cartridge.new(
      tag: tag, version: version, memories: memories,
      preferences: Personality::PreferencesConfig.from_hash(preferences)
    )
  end

  def mem(subject, content)
    Personality::TrainingMemory.new(subject: subject, content: content)
  end

  describe "#build_instructions" do
    it "returns empty string for empty memories" do
      expect(builder.build_instructions(make_cart(memories: []))).to eq("")
    end

    it "returns empty string for nil memories" do
      cart = Personality::Cartridge.new(tag: "x", memories: nil,
        preferences: Personality::PreferencesConfig.from_hash({}))
      expect(builder.build_instructions(cart)).to eq("")
    end

    it "includes identity name and type in header" do
      cart = make_cart(
        memories: [mem("self.trait.bold", "fearless")],
        preferences: {"identity" => {"name" => "BT", "type" => "Titan AI"}}
      )
      result = builder.build_instructions(cart)
      expect(result).to include("You are **BT**")
      expect(result).to include("a Titan AI")
    end

    it "includes identity name without type" do
      cart = make_cart(
        memories: [mem("self.trait", "brave")],
        preferences: {"identity" => {"name" => "Bot"}}
      )
      result = builder.build_instructions(cart)
      expect(result).to include("You are **Bot**")
      expect(result).not_to include(", a ")
    end

    it "falls back to tag when no identity name" do
      cart = make_cart(tag: "mytag", memories: [mem("self.trait", "brave")])
      result = builder.build_instructions(cart)
      expect(result).to include("**mytag**")
    end

    it "skips tag fallback when tag is empty" do
      cart = make_cart(tag: "", memories: [mem("other.thing", "data")])
      result = builder.build_instructions(cart)
      expect(result).not_to include("roleplaying as")
    end

    it "includes tagline as quote" do
      cart = make_cart(
        memories: [mem("self.trait", "brave")],
        preferences: {"identity" => {"name" => "BT", "tagline" => "Protocol 3: Protect the Pilot"}}
      )
      result = builder.build_instructions(cart)
      expect(result).to include('"Protocol 3: Protect the Pilot"')
    end

    it "formats self.* memories by SECTION_ORDER" do
      cart = make_cart(
        memories: [
          mem("self.quote.famous", "Trust me."),
          mem("self.trait.bold", "fearless"),
          mem("self.speech.formal", "military terms"),
          mem("self.protocol.core", "protect pilot")
        ],
        preferences: {"identity" => {"name" => "Bot"}}
      )
      result = builder.build_instructions(cart)

      # Verify sections appear
      expect(result).to include("### Personality Traits")
      expect(result).to include("### Protocols")
      expect(result).to include("### Speech Patterns")
      expect(result).to include("### Iconic Quotes")

      # Verify trait appears before quote (SECTION_ORDER)
      trait_pos = result.index("Personality Traits")
      quote_pos = result.index("Iconic Quotes")
      expect(trait_pos).to be < quote_pos
    end

    it "handles self.* sub-categories not in SECTION_ORDER" do
      cart = make_cart(
        memories: [mem("self.custom_cat.item", "something")],
        preferences: {"identity" => {"name" => "Bot"}}
      )
      result = builder.build_instructions(cart)
      expect(result).to include("### Custom_cat")
    end

    it "handles self with no sub-category (general)" do
      cart = make_cart(
        memories: [mem("self", "top-level")],
        preferences: {"identity" => {"name" => "Bot"}}
      )
      result = builder.build_instructions(cart)
      expect(result).to include("- top-level")
    end

    it "formats user.* memories" do
      cart = make_cart(memories: [mem("user.name", "Call them Pilot")])
      result = builder.build_instructions(cart)
      expect(result).to include("### User Interaction")
      expect(result).to include("- Call them Pilot")
    end

    it "formats meta.* memories" do
      cart = make_cart(memories: [mem("meta.system", "config value")])
      result = builder.build_instructions(cart)
      expect(result).to include("### Meta Information")
      expect(result).to include("- config value")
    end

    it "strips identity.* from body" do
      cart = make_cart(memories: [mem("identity.name", "Bot"), mem("self.trait", "brave")])
      result = builder.build_instructions(cart)
      # identity section is removed, not rendered as a separate heading
      lines = result.lines.select { |l| l.include?("### Identity") }
      # Should be in SECTION_ORDER as self.identity, not as top-level identity
      expect(result).to include("### Personality Traits")
    end

    it "handles remaining/unknown top-level categories" do
      cart = make_cart(memories: [mem("custom.thing", "data")])
      result = builder.build_instructions(cart)
      expect(result).to include("### Custom")
      expect(result).to include("- data")
    end

    it "uses known CATEGORY_TITLES for remaining groups" do
      cart = make_cart(memories: [mem("knowledge.fact", "earth is round")])
      result = builder.build_instructions(cart)
      expect(result).to include("### Knowledge")
    end

    it "sorts remaining categories alphabetically" do
      cart = make_cart(memories: [
        mem("zzz.item", "last"),
        mem("aaa.item", "first")
      ])
      result = builder.build_instructions(cart)
      aaa_pos = result.index("Aaa")
      zzz_pos = result.index("Zzz")
      expect(aaa_pos).to be < zzz_pos
    end

    it "works via class method shortcut" do
      cart = make_cart(memories: [mem("self.trait", "test")])
      result = described_class.build_instructions(cart)
      expect(result).to include("- test")
    end

    it "includes all known SECTION_ORDER sections" do
      memories = described_class::SECTION_ORDER.map { |s| mem("self.#{s}.item", "#{s} data") }
      cart = make_cart(memories: memories, preferences: {"identity" => {"name" => "Bot"}})
      result = builder.build_instructions(cart)

      expect(result).to include("### Identity")
      expect(result).to include("### Personality Traits")
      expect(result).to include("### Protocols")
      expect(result).to include("### Speech Patterns")
      expect(result).to include("### Capabilities")
      expect(result).to include("### Relationships")
      expect(result).to include("### Iconic Quotes")
      expect(result).to include("### Logic & Reasoning")
      expect(result).to include("### Beliefs & Values")
      expect(result).to include("### Behaviors")
      expect(result).to include("### Emotional Tendencies")
      expect(result).to include("### Goals & Motivations")
      expect(result).to include("### Background & Memories")
      expect(result).to include("### Quirks & Mannerisms")
      expect(result).to include("### Knowledge")
      expect(result).to include("### History & Backstory")
    end
  end

  describe "#build_greeting" do
    it "uses greeting memory with {{user}} substitution" do
      cart = make_cart(memories: [mem("self.greeting", "Hello {{user}}, ready?")])
      expect(builder.build_greeting(cart, user_name: "Adam")).to eq("Hello Adam, ready?")
    end

    it "uses salutation memory" do
      cart = make_cart(memories: [mem("speech.salutation", "Hi {{USER_ID}}")])
      expect(builder.build_greeting(cart, user_name: "Pilot")).to eq("Hi Pilot")
    end

    it "substitutes {{TIME_GREETING}}" do
      cart = make_cart(memories: [mem("self.greeting", "{{TIME_GREETING}}, sir")])
      result = builder.build_greeting(cart)
      expect(result).to match(/Good (morning|afternoon|evening), sir/)
    end

    it "defaults user_name to User" do
      cart = make_cart(memories: [mem("self.greeting", "Hi {{user}}")])
      expect(builder.build_greeting(cart)).to eq("Hi User")
    end

    it "defaults USER_ID to User" do
      cart = make_cart(memories: [mem("self.greeting", "Hi {{USER_ID}}")])
      expect(builder.build_greeting(cart)).to eq("Hi User")
    end

    it "falls back to identity name greeting" do
      cart = make_cart(
        memories: [mem("self.trait", "brave")],
        preferences: {"identity" => {"name" => "BT-7274"}}
      )
      expect(builder.build_greeting(cart)).to eq("Hello, I am BT-7274.")
    end

    it "falls back to tag when no identity name" do
      cart = make_cart(tag: "mybot", memories: [])
      expect(builder.build_greeting(cart)).to eq("Hello, I am mybot.")
    end

    it "uses tag when identity name is empty" do
      cart = make_cart(tag: "tagbot", preferences: {"identity" => {"name" => ""}})
      expect(builder.build_greeting(cart)).to eq("Hello, I am tagbot.")
    end
  end

  describe "#build_summary" do
    it "includes name, type, and version" do
      cart = make_cart(
        version: "2.0",
        preferences: {"identity" => {"name" => "Bot", "type" => "AI"}}
      )
      expect(builder.build_summary(cart)).to eq("Bot (AI) v2.0")
    end

    it "falls back to tag" do
      cart = make_cart(tag: "mybot")
      expect(builder.build_summary(cart)).to start_with("mybot")
    end

    it "omits type when empty" do
      cart = make_cart(preferences: {"identity" => {"name" => "Bot"}})
      summary = builder.build_summary(cart)
      expect(summary).to include("Bot")
      expect(summary).not_to include("()")
    end

    it "omits version when empty" do
      cart = Personality::Cartridge.new(
        tag: "x", version: "",
        preferences: Personality::PreferencesConfig.from_hash({"identity" => {"name" => "Bot"}})
      )
      expect(builder.build_summary(cart)).to eq("Bot")
    end

    it "omits version when nil" do
      cart = Personality::Cartridge.new(
        tag: "x", version: nil,
        preferences: Personality::PreferencesConfig.from_hash({"identity" => {"name" => "Bot"}})
      )
      expect(builder.build_summary(cart)).to eq("Bot")
    end

    it "returns 'Persona loaded' when nothing available" do
      cart = Personality::Cartridge.new(
        tag: "", version: "",
        preferences: Personality::PreferencesConfig.from_hash({})
      )
      expect(builder.build_summary(cart)).to eq("Persona loaded")
    end
  end

  describe "time_greeting (private)" do
    it "returns morning before noon" do
      allow(Time).to receive(:now).and_return(Time.new(2026, 1, 1, 9, 0, 0))
      expect(builder.send(:time_greeting)).to eq("Good morning")
    end

    it "returns afternoon between noon and 5pm" do
      allow(Time).to receive(:now).and_return(Time.new(2026, 1, 1, 14, 0, 0))
      expect(builder.send(:time_greeting)).to eq("Good afternoon")
    end

    it "returns evening after 5pm" do
      allow(Time).to receive(:now).and_return(Time.new(2026, 1, 1, 19, 0, 0))
      expect(builder.send(:time_greeting)).to eq("Good evening")
    end
  end
end
