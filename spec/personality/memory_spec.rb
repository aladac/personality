# frozen_string_literal: true

require "personality/memory"
require "personality/db"
require "personality/cart"
require "tmpdir"

RSpec.describe Personality::Memory do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_memory_test_#{$$}_#{rand(10000)}.db") }
  let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }
  let(:cart) { Personality::Cart.find_or_create("test") }
  let(:memory) { described_class.new(cart_id: cart[:id]) }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    Personality::DB.migrate!(path: tmp_db)

    # Stub embedding generation
    allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
  end

  describe "#store" do
    it "stores a memory and returns id" do
      result = memory.store(subject: "test", content: "hello world")
      expect(result[:id]).to be_a(Integer)
      expect(result[:subject]).to eq("test")
    end

    it "stores metadata as JSON" do
      memory.store(subject: "test", content: "data", metadata: {source: "hook"})
      db = Personality::DB.connection(path: tmp_db)
      row = db.execute("SELECT metadata FROM memories WHERE id = 1").first
      expect(JSON.parse(row["metadata"])).to eq({"source" => "hook"})
    end

    it "inserts embedding into vec_memories" do
      result = memory.store(subject: "test", content: "hello")
      db = Personality::DB.connection(path: tmp_db)
      vec_row = db.execute("SELECT * FROM vec_memories WHERE memory_id = ?", [result[:id]]).first
      expect(vec_row).not_to be_nil
    end
  end

  describe "#recall" do
    before do
      memory.store(subject: "ruby", content: "Ruby is a programming language")
      memory.store(subject: "python", content: "Python is also a language")
      memory.store(subject: "cooking", content: "How to make pasta")
    end

    it "returns memories sorted by distance" do
      result = memory.recall(query: "programming languages")
      expect(result[:memories]).to be_an(Array)
      expect(result[:memories].length).to be <= 5
    end

    it "respects limit" do
      result = memory.recall(query: "test", limit: 1)
      expect(result[:memories].length).to be <= 1
    end

    it "filters by subject" do
      result = memory.recall(query: "language", subject: "ruby")
      result[:memories].each do |m|
        expect(m[:subject]).to eq("ruby")
      end
    end

    it "returns empty when no embeddings match" do
      allow(Personality::Embedding).to receive(:generate).and_return([])
      result = memory.recall(query: "anything")
      expect(result[:memories]).to eq([])
    end
  end

  describe "#search" do
    before do
      memory.store(subject: "ruby", content: "Ruby stuff")
      memory.store(subject: "ruby", content: "More Ruby")
      memory.store(subject: "python", content: "Python stuff")
    end

    it "returns all memories without filter" do
      result = memory.search
      expect(result[:memories].length).to eq(3)
    end

    it "filters by subject" do
      result = memory.search(subject: "ruby")
      expect(result[:memories].length).to eq(2)
      result[:memories].each { |m| expect(m[:subject]).to eq("ruby") }
    end

    it "respects limit" do
      result = memory.search(limit: 1)
      expect(result[:memories].length).to eq(1)
    end
  end

  describe "#forget" do
    it "deletes an existing memory" do
      stored = memory.store(subject: "temp", content: "delete me")
      result = memory.forget(id: stored[:id])
      expect(result[:deleted]).to be true
    end

    it "returns false for nonexistent memory" do
      result = memory.forget(id: 99999)
      expect(result[:deleted]).to be false
    end

    it "also removes from vec_memories" do
      stored = memory.store(subject: "temp", content: "delete me")
      memory.forget(id: stored[:id])
      db = Personality::DB.connection(path: tmp_db)
      vec_row = db.execute("SELECT * FROM vec_memories WHERE memory_id = ?", [stored[:id]]).first
      expect(vec_row).to be_nil
    end
  end

  describe "#list" do
    it "returns empty when no memories" do
      result = memory.list
      expect(result[:subjects]).to eq([])
    end

    it "returns subjects with counts" do
      memory.store(subject: "alpha", content: "one")
      memory.store(subject: "alpha", content: "two")
      memory.store(subject: "beta", content: "three")

      result = memory.list
      expect(result[:subjects].length).to eq(2)

      alpha = result[:subjects].find { |s| s[:subject] == "alpha" }
      expect(alpha[:count]).to eq(2)
    end
  end

  describe "cart isolation" do
    it "does not see memories from other carts" do
      other_cart = Personality::Cart.find_or_create("other")
      other_memory = described_class.new(cart_id: other_cart[:id])

      memory.store(subject: "mine", content: "my data")
      other_memory.store(subject: "theirs", content: "their data")

      expect(memory.list[:subjects].length).to eq(1)
      expect(other_memory.list[:subjects].length).to eq(1)

      mine = memory.search
      expect(mine[:memories].first[:subject]).to eq("mine")
    end
  end
end
