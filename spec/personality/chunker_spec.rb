# frozen_string_literal: true

require "personality/chunker"

RSpec.describe Personality::Chunker do
  describe ".split" do
    it "returns empty array for nil" do
      expect(described_class.split(nil)).to eq([])
    end

    it "returns empty array for short text" do
      expect(described_class.split("hello")).to eq([])
    end

    it "returns single chunk for text under size limit" do
      text = "a" * 500
      result = described_class.split(text)
      expect(result).to eq([text])
    end

    it "returns single chunk for text exactly at size limit" do
      text = "a" * 2000
      result = described_class.split(text)
      expect(result).to eq([text])
    end

    it "splits text into overlapping chunks" do
      text = "a" * 5000
      result = described_class.split(text)

      expect(result.length).to be > 1
      expect(result.first.length).to eq(2000)
    end

    it "creates overlapping windows" do
      text = "a" * 4000
      result = described_class.split(text, size: 2000, overlap: 200)

      # First chunk: 0..1999 (2000 chars)
      # Second chunk: 1800..3799 (2000 chars)
      # Third chunk: 3600..3999 (400 chars)
      expect(result.length).to eq(3)
      expect(result[0].length).to eq(2000)
      expect(result[1].length).to eq(2000)
      expect(result[2].length).to eq(400)
    end

    it "accepts custom size and overlap" do
      text = "a" * 1000
      result = described_class.split(text, size: 300, overlap: 50)

      expect(result.length).to eq(4)
      expect(result.first.length).to eq(300)
    end

    it "skips text shorter than MIN_LENGTH" do
      expect(described_class.split("123456789")).to eq([])
      expect(described_class.split("1234567890")).to eq(["1234567890"])
    end
  end
end
