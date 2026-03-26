# frozen_string_literal: true

require "personality"
require "tmpdir"

RSpec.describe "Integration" do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_integration_#{$$}_#{rand(10000)}.db") }
  let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
  end

  describe "init → store memory → recall → verify" do
    it "completes the full memory lifecycle" do
      # 1. Migrate (init equivalent)
      Personality::DB.migrate!(path: tmp_db)

      # 2. Create a persona
      cart = Personality::Cart.create("integration-test", name: "Test Bot")
      expect(cart[:tag]).to eq("integration-test")

      # 3. Store memories
      mem = Personality::Memory.new(cart_id: cart[:id])
      r1 = mem.store(subject: "ruby", content: "Ruby is great for scripting")
      r2 = mem.store(subject: "rust", content: "Rust is great for performance")
      r3 = mem.store(subject: "cooking", content: "Pasta carbonara needs guanciale")

      expect(r1[:id]).to be_a(Integer)
      expect(r2[:id]).to be_a(Integer)
      expect(r3[:id]).to be_a(Integer)

      # 4. List subjects
      subjects = mem.list[:subjects]
      expect(subjects.length).to eq(3)

      # 5. Recall by query
      results = mem.recall(query: "programming", limit: 2)
      expect(results[:memories].length).to eq(2)
      expect(results[:memories].first).to have_key(:distance)

      # 6. Search by subject
      ruby_results = mem.search(subject: "ruby")
      expect(ruby_results[:memories].length).to eq(1)
      expect(ruby_results[:memories].first[:content]).to include("Ruby")

      # 7. Forget one
      mem.forget(id: r3[:id])
      expect(mem.list[:subjects].length).to eq(2)

      # 8. Verify cart isolation
      other_cart = Personality::Cart.create("other")
      other_mem = Personality::Memory.new(cart_id: other_cart[:id])
      expect(other_mem.list[:subjects]).to eq([])
    end
  end

  describe "index code → search → verify" do
    let(:tmp_dir) { Dir.mktmpdir("psn_integration_files") }

    after { FileUtils.rm_rf(tmp_dir) }

    it "completes the full indexing lifecycle" do
      Personality::DB.migrate!(path: tmp_db)
      indexer = Personality::Indexer.new

      # 1. Create test files
      File.write(File.join(tmp_dir, "app.rb"), <<~RUBY * 3)
        class Application
          def initialize
            @config = load_config
          end

          def run
            puts "Starting application"
          end
        end
      RUBY

      File.write(File.join(tmp_dir, "README.md"), <<~MD * 3)
        # My Project

        This is a Ruby application that does interesting things.
        It uses SQLite for storage and Ollama for embeddings.
      MD

      File.write(File.join(tmp_dir, "tiny.rb"), "x = 1") # Too short, should be skipped

      # 2. Index code
      code_result = indexer.index_code(path: tmp_dir, project: "test-proj")
      expect(code_result[:indexed]).to be > 0
      expect(code_result[:project]).to eq("test-proj")
      expect(code_result[:errors]).to eq([])

      # 3. Index docs
      doc_result = indexer.index_docs(path: tmp_dir, project: "test-proj")
      expect(doc_result[:indexed]).to be > 0

      # 4. Check status
      status = indexer.status(project: "test-proj")
      expect(status[:code_index].first[:count]).to be > 0
      expect(status[:doc_index].first[:count]).to be > 0

      # 5. Search
      search_result = indexer.search(query: "Ruby application", limit: 5)
      expect(search_result[:results]).not_to be_empty
      expect(search_result[:results].first).to have_key(:distance)
      expect(search_result[:results].first).to have_key(:path)

      # 6. Search by type
      code_only = indexer.search(query: "test", type: :code)
      code_only[:results].each { |r| expect(r[:type]).to eq(:code) }

      # 7. Re-index is idempotent
      indexer.index_code(path: tmp_dir, project: "test-proj")
      status2 = indexer.status(project: "test-proj")
      expect(status2[:code_index].first[:count]).to eq(status[:code_index].first[:count])

      # 8. Index single file (hook simulation)
      new_file = File.join(tmp_dir, "new_module.rb")
      File.write(new_file, "module NewModule\n  def hello; end\nend\n" * 5)
      indexer.index_single_file(file_path: new_file, project: "test-proj")
      status3 = indexer.status(project: "test-proj")
      expect(status3[:code_index].first[:count]).to be > status[:code_index].first[:count]

      # 9. Clear
      indexer.clear(project: "test-proj", type: :code)
      status4 = indexer.status(project: "test-proj")
      expect(status4[:code_index]).to eq([])
      expect(status4[:doc_index].first[:count]).to be > 0 # docs untouched
    end
  end

  describe "MCP server end-to-end" do
    it "handles tool calls through the protocol" do
      require "personality/mcp/server"

      Personality::DB.migrate!(path: tmp_db)
      server = Personality::MCP::Server.new
      mcp = server.instance_variable_get(:@server)

      # Initialize protocol
      mcp.handle({jsonrpc: "2.0", id: 0, method: "initialize",
                  params: {protocolVersion: "2024-11-05", capabilities: {}, clientInfo: {name: "test", version: "1.0"}}})

      # Store via MCP
      r = mcp.handle({jsonrpc: "2.0", id: 1, method: "tools/call",
                      params: {name: "memory.store", arguments: {subject: "mcp-test", content: "MCP works"}}})
      stored = JSON.parse(r[:result][:content].first[:text])
      expect(stored["subject"]).to eq("mcp-test")

      # List via MCP
      r = mcp.handle({jsonrpc: "2.0", id: 2, method: "tools/call",
                      params: {name: "memory.list", arguments: {}}})
      listed = JSON.parse(r[:result][:content].first[:text])
      expect(listed["subjects"].first["subject"]).to eq("mcp-test")

      # Read resource
      r = mcp.handle({jsonrpc: "2.0", id: 3, method: "resources/read",
                      params: {uri: "memory://stats"}})
      stats = JSON.parse(r[:result][:contents].first[:text])
      expect(stats["total_memories"]).to eq(1)
    end
  end
end
