# frozen_string_literal: true

require "personality/embedding"

RSpec.describe Personality::Embedding do
  describe ".generate" do
    context "with a stubbed Ollama response" do
      let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }

      before do
        stub_request = instance_double(Net::HTTPOK, is_a?: true, code: "200", body: {embedding: fake_embedding}.to_json)
        allow(stub_request).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:post).and_return(stub_request)
      end

      it "returns an array of floats" do
        result = described_class.generate("hello world")
        expect(result).to be_an(Array)
        expect(result.length).to eq(768)
        expect(result.first).to be_a(Float)
      end

      it "truncates input to MAX_INPUT_LENGTH" do
        long_text = "a" * 20_000
        expect(Net::HTTP).to receive(:post) do |_uri, body, _headers|
          parsed = JSON.parse(body)
          expect(parsed["prompt"].length).to eq(8000)
          instance_double(Net::HTTPOK).tap do |resp|
            allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
            allow(resp).to receive(:body).and_return({embedding: fake_embedding}.to_json)
          end
        end

        described_class.generate(long_text)
      end
    end

    it "returns empty array for empty text" do
      expect(described_class.generate("")).to eq([])
      expect(described_class.generate(nil)).to eq([])
    end

    it "raises Error on connection failure" do
      allow(Net::HTTP).to receive(:post).and_raise(Errno::ECONNREFUSED)
      expect {
        described_class.generate("test")
      }.to raise_error(Errno::ECONNREFUSED)
    end

    it "raises Error on bad response" do
      bad_response = instance_double(Net::HTTPInternalServerError, code: "500", body: "error")
      allow(bad_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:post).and_return(bad_response)

      expect {
        described_class.generate("test")
      }.to raise_error(Personality::Embedding::Error, /500/)
    end
  end

  describe "constants" do
    it "has expected dimensions" do
      expect(described_class::DIMENSIONS).to eq(768)
    end

    it "has expected max input length" do
      expect(described_class::MAX_INPUT_LENGTH).to eq(8000)
    end
  end
end
