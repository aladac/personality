# frozen_string_literal: true

require "personality/cart"
require "personality/db"
require "tmpdir"

RSpec.describe Personality::Cart do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_cart_test_#{$$}_#{rand(10000)}.db") }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    Personality::DB.migrate!(path: tmp_db)
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
  end

  describe ".find_or_create" do
    it "creates a new cart" do
      result = described_class.find_or_create("test-cart")
      expect(result[:tag]).to eq("test-cart")
      expect(result[:id]).to be_a(Integer)
    end

    it "returns existing cart on second call" do
      first = described_class.find_or_create("test-cart")
      second = described_class.find_or_create("test-cart")
      expect(first[:id]).to eq(second[:id])
    end
  end

  describe ".active" do
    it "returns default cart when env not set" do
      allow(ENV).to receive(:fetch).with("PERSONALITY_CART", "default").and_return("default")
      result = described_class.active
      expect(result[:tag]).to eq("default")
    end

    it "uses PERSONALITY_CART env var" do
      allow(ENV).to receive(:fetch).with("PERSONALITY_CART", "default").and_return("bt7274")
      result = described_class.active
      expect(result[:tag]).to eq("bt7274")
    end
  end

  describe ".list" do
    it "returns empty array when no carts" do
      expect(described_class.list).to eq([])
    end

    it "returns all carts" do
      described_class.create("alpha")
      described_class.create("beta")
      result = described_class.list
      expect(result.length).to eq(2)
      expect(result.map { |c| c[:tag] }).to contain_exactly("alpha", "beta")
    end
  end

  describe ".create" do
    it "creates cart with attributes" do
      result = described_class.create("bot", name: "My Bot", type: "assistant", tagline: "Helpful")
      expect(result[:tag]).to eq("bot")
      expect(result[:name]).to eq("My Bot")
      expect(result[:type]).to eq("assistant")
      expect(result[:tagline]).to eq("Helpful")
    end

    it "returns existing cart if tag exists" do
      first = described_class.create("bot")
      second = described_class.create("bot", name: "Different")
      expect(first[:id]).to eq(second[:id])
    end
  end

  describe ".find" do
    it "returns nil for nonexistent tag" do
      expect(described_class.find("nonexistent")).to be_nil
    end

    it "returns cart hash for existing tag" do
      described_class.create("findme")
      result = described_class.find("findme")
      expect(result[:tag]).to eq("findme")
    end
  end

  describe ".use" do
    it "creates and returns the cart" do
      result = described_class.use("new-persona")
      expect(result[:tag]).to eq("new-persona")
      expect(result[:id]).to be_a(Integer)
    end
  end
end
