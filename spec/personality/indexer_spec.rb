# frozen_string_literal: true

require "personality/indexer"
require "personality/db"
require "tmpdir"

RSpec.describe Personality::Indexer do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_indexer_test_#{$$}_#{rand(10000)}.db") }
  let(:tmp_dir) { Dir.mktmpdir("psn_indexer_files") }
  let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }
  let(:indexer) { described_class.new }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    Personality::DB.migrate!(path: tmp_db)

    allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
    FileUtils.rm_rf(tmp_dir)
  end

  def create_file(name, content)
    path = File.join(tmp_dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "#index_code" do
    before do
      create_file("app.rb", "class App\n  def run\n    puts 'hello'\n  end\nend\n" * 5)
      create_file("lib/helper.py", "def helper():\n    return True\n" * 5)
      create_file("readme.md", "# This is docs, not code")
      create_file("tiny.rb", "x = 1")  # Too short
    end

    it "indexes code files and returns count" do
      result = indexer.index_code(path: tmp_dir)
      expect(result[:indexed]).to be > 0
      expect(result[:project]).to eq(File.basename(tmp_dir))
      expect(result[:errors]).to eq([])
    end

    it "skips non-code extensions" do
      indexer.index_code(path: tmp_dir)
      db = Personality::DB.connection(path: tmp_db)
      paths = db.execute("SELECT DISTINCT path FROM code_chunks").map { |r| r["path"] }
      expect(paths.none? { |p| p.end_with?(".md") }).to be true
    end

    it "skips files shorter than MIN_LENGTH" do
      db = Personality::DB.connection(path: tmp_db)
      indexer.index_code(path: tmp_dir)
      paths = db.execute("SELECT DISTINCT path FROM code_chunks").map { |r| r["path"] }
      expect(paths.none? { |p| p.end_with?("tiny.rb") }).to be true
    end

    it "uses custom project name" do
      result = indexer.index_code(path: tmp_dir, project: "my-project")
      expect(result[:project]).to eq("my-project")
    end

    it "is idempotent — re-index replaces old chunks" do
      indexer.index_code(path: tmp_dir, project: "test")
      first_count = indexer.status(project: "test")[:code_index].sum { |s| s[:count] }

      indexer.index_code(path: tmp_dir, project: "test")
      second_count = indexer.status(project: "test")[:code_index].sum { |s| s[:count] }

      expect(first_count).to eq(second_count)
    end
  end

  describe "#index_docs" do
    before do
      create_file("README.md", "# Project\n\nThis is documentation.\n" * 5)
      create_file("docs/guide.txt", "A guide to the system.\n" * 5)
      create_file("app.rb", "# Not a doc file")
    end

    it "indexes doc files" do
      result = indexer.index_docs(path: tmp_dir)
      expect(result[:indexed]).to be > 0
    end

    it "skips non-doc extensions" do
      indexer.index_docs(path: tmp_dir)
      db = Personality::DB.connection(path: tmp_db)
      paths = db.execute("SELECT DISTINCT path FROM doc_chunks").map { |r| r["path"] }
      expect(paths.none? { |p| p.end_with?(".rb") }).to be true
    end
  end

  describe "#search" do
    before do
      create_file("app.rb", "class App\n  def run\n    puts 'hello world'\n  end\nend\n" * 5)
      create_file("README.md", "# Documentation\n\nThis project does things.\n" * 5)
      indexer.index_code(path: tmp_dir, project: "test")
      indexer.index_docs(path: tmp_dir, project: "test")
    end

    it "returns results" do
      result = indexer.search(query: "hello world")
      expect(result[:results]).to be_an(Array)
      expect(result[:results].length).to be > 0
    end

    it "filters by type" do
      result = indexer.search(query: "test", type: :code)
      result[:results].each { |r| expect(r[:type]).to eq(:code) }
    end

    it "filters by project" do
      result = indexer.search(query: "test", project: "test")
      result[:results].each { |r| expect(r[:project]).to eq("test") }
    end

    it "respects limit" do
      result = indexer.search(query: "test", limit: 1)
      expect(result[:results].length).to be <= 1
    end

    it "returns empty for no embeddings" do
      allow(Personality::Embedding).to receive(:generate).and_return([])
      result = indexer.search(query: "anything")
      expect(result[:results]).to eq([])
    end
  end

  describe "#status" do
    it "returns empty stats for fresh db" do
      result = indexer.status
      expect(result[:code_index]).to eq([])
      expect(result[:doc_index]).to eq([])
    end

    it "returns counts after indexing" do
      create_file("app.rb", "class App\n  def run\n    puts 'test'\n  end\nend\n" * 5)
      indexer.index_code(path: tmp_dir, project: "myproj")

      result = indexer.status
      expect(result[:code_index].length).to eq(1)
      expect(result[:code_index].first[:project]).to eq("myproj")
      expect(result[:code_index].first[:count]).to be > 0
    end

    it "filters by project" do
      create_file("app.rb", "class App; end\n" * 5)
      indexer.index_code(path: tmp_dir, project: "a")

      result = indexer.status(project: "nonexistent")
      expect(result[:code_index]).to eq([])
    end
  end

  describe "#clear" do
    before do
      create_file("app.rb", "class App; end\n" * 5)
      create_file("README.md", "# Docs\n" * 5)
      indexer.index_code(path: tmp_dir, project: "test")
      indexer.index_docs(path: tmp_dir, project: "test")
    end

    it "clears all when no project specified" do
      indexer.clear
      result = indexer.status
      expect(result[:code_index]).to eq([])
      expect(result[:doc_index]).to eq([])
    end

    it "clears only specified project" do
      create_file("other.rb", "class Other; end\n" * 5)
      indexer.index_code(path: tmp_dir, project: "other")

      indexer.clear(project: "test")
      result = indexer.status
      expect(result[:code_index].length).to eq(1)
      expect(result[:code_index].first[:project]).to eq("other")
    end

    it "clears only specified type" do
      indexer.clear(type: :code)
      result = indexer.status
      expect(result[:code_index]).to eq([])
      expect(result[:doc_index].length).to be > 0
    end
  end

  describe "#index_single_file" do
    it "indexes a code file" do
      path = create_file("single.rb", "class Single\n  def hello; end\nend\n" * 5)
      indexer.index_single_file(file_path: path, project: "test")

      result = indexer.status(project: "test")
      expect(result[:code_index].first[:count]).to be > 0
    end

    it "indexes a doc file" do
      path = create_file("doc.md", "# Guide\n\nSome documentation.\n" * 5)
      indexer.index_single_file(file_path: path, project: "test")

      result = indexer.status(project: "test")
      expect(result[:doc_index].first[:count]).to be > 0
    end

    it "ignores unknown extensions" do
      path = create_file("data.csv", "a,b,c\n1,2,3\n" * 5)
      indexer.index_single_file(file_path: path, project: "test")

      result = indexer.status(project: "test")
      expect(result[:code_index]).to eq([])
      expect(result[:doc_index]).to eq([])
    end

    it "ignores nonexistent files" do
      expect { indexer.index_single_file(file_path: "/nonexistent.rb", project: "test") }.not_to raise_error
    end
  end
end
