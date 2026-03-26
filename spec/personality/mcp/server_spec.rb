# frozen_string_literal: true

require "personality"
require "personality/mcp/server"
require "tmpdir"

RSpec.describe Personality::MCP::Server do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_mcp_test_#{$$}_#{rand(10000)}.db") }
  let(:server) { described_class.new }
  let(:mcp) { server.instance_variable_get(:@server) }
  let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    Personality::DB.migrate!(path: tmp_db)
    allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)

    # MCP requires initialize before other calls
    mcp.handle({jsonrpc: "2.0", id: 0, method: "initialize",
                params: {protocolVersion: "2024-11-05", capabilities: {}, clientInfo: {name: "test", version: "1.0"}}})
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
  end

  def call(method, params = {})
    response = mcp.handle({jsonrpc: "2.0", id: rand(10000), method: method, params: params})
    response[:result]
  end

  describe "tool registration" do
    it "registers 18 tools total" do
      result = call("tools/list")
      expect(result[:tools].length).to eq(18)
    end

    it "includes memory tools" do
      names = call("tools/list")[:tools].map { |t| t[:name] }
      expect(names).to include("memory.store", "memory.recall", "memory.search", "memory.forget", "memory.list")
    end

    it "includes index tools" do
      names = call("tools/list")[:tools].map { |t| t[:name] }
      expect(names).to include("index.code", "index.docs", "index.search", "index.status", "index.clear")
    end

    it "includes cart tools" do
      names = call("tools/list")[:tools].map { |t| t[:name] }
      expect(names).to include("cart.list", "cart.use", "cart.create")
    end
  end

  describe "tool calls" do
    def call_tool(name, arguments = {})
      result = call("tools/call", {name: name, arguments: arguments})
      # MCP gem returns {content: [{type: "text", text: "..."}], isError: false}
      JSON.parse(result[:content].first[:text])
    end

    it "handles memory.store" do
      content = call_tool("memory.store", {subject: "test", content: "hello"})
      expect(content["id"]).to be_a(Integer)
      expect(content["subject"]).to eq("test")
    end

    it "handles memory.list after store" do
      call_tool("memory.store", {subject: "test", content: "data"})
      content = call_tool("memory.list")
      expect(content["subjects"]).to be_an(Array)
      expect(content["subjects"].first["subject"]).to eq("test")
    end

    it "handles memory.forget" do
      stored = call_tool("memory.store", {subject: "temp", content: "delete"})
      content = call_tool("memory.forget", {id: stored["id"]})
      expect(content["deleted"]).to be true
    end

    it "handles cart.list" do
      content = call_tool("cart.list")
      expect(content).to have_key("carts")
    end

    it "handles cart.create" do
      content = call_tool("cart.create", {tag: "test-bot", name: "Test"})
      expect(content["tag"]).to eq("test-bot")
    end

    it "handles index.status" do
      content = call_tool("index.status")
      expect(content).to have_key("code_index")
      expect(content).to have_key("doc_index")
    end
  end

  describe "resources" do
    it "lists resources" do
      result = call("resources/list")
      resources = result[:resources]
      expect(resources.length).to eq(3)
    end

    it "reads memory://subjects" do
      result = call("resources/read", {uri: "memory://subjects"})
      text = JSON.parse(result[:contents].first[:text])
      expect(text).to have_key("subjects")
    end

    it "reads memory://stats" do
      result = call("resources/read", {uri: "memory://stats"})
      text = JSON.parse(result[:contents].first[:text])
      expect(text).to have_key("total_memories")
    end

    it "reads memory://recent" do
      call("tools/call", {name: "memory.store", arguments: {subject: "test", content: "recent"}})
      result = call("resources/read", {uri: "memory://recent"})
      text = JSON.parse(result[:contents].first[:text])
      expect(text["memories"].length).to be >= 1
    end
  end

  describe "protocol" do
    it "returns server info on initialize" do
      # Already initialized in before, just verify a fresh call
      response = mcp.handle({jsonrpc: "2.0", id: 999, method: "initialize",
                             params: {protocolVersion: "2024-11-05", capabilities: {}, clientInfo: {name: "t", version: "1"}}})
      expect(response[:result][:serverInfo][:name]).to eq("core")
    end
  end
end
