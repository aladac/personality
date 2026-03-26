# frozen_string_literal: true

require "personality/db"
require "tmpdir"

RSpec.describe Personality::DB do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_db_test_#{$$}_#{rand(10000)}.db") }

  after do
    described_class.reset!
    FileUtils.rm_f(tmp_db)
  end

  describe ".connection" do
    it "returns a SQLite3::Database" do
      db = described_class.connection(path: tmp_db)
      expect(db).to be_a(SQLite3::Database)
    end

    it "returns the same connection on repeated calls" do
      db1 = described_class.connection(path: tmp_db)
      db2 = described_class.connection(path: tmp_db)
      expect(db1).to equal(db2)
    end

    it "enables WAL journal mode" do
      db = described_class.connection(path: tmp_db)
      mode = db.execute("PRAGMA journal_mode").dig(0, "journal_mode")
      expect(mode).to eq("wal")
    end

    it "enables foreign keys" do
      db = described_class.connection(path: tmp_db)
      fk = db.execute("PRAGMA foreign_keys").dig(0, "foreign_keys")
      expect(fk).to eq(1)
    end

    it "loads sqlite-vec extension" do
      db = described_class.connection(path: tmp_db)
      version = db.execute("SELECT vec_version() AS v").dig(0, "v")
      expect(version).to match(/^v\d+/)
    end
  end

  describe ".migrate!" do
    it "creates all expected tables" do
      described_class.migrate!(path: tmp_db)
      db = described_class.connection(path: tmp_db)

      tables = db.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
      ).map { |r| r["name"] }

      expect(tables).to include(
        "carts", "memories", "code_chunks", "doc_chunks", "schema_version"
      )
    end

    it "creates vec0 virtual tables" do
      described_class.migrate!(path: tmp_db)
      db = described_class.connection(path: tmp_db)

      tables = db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'vec_%' ORDER BY name"
      ).map { |r| r["name"] }

      expect(tables).to include("vec_memories", "vec_code", "vec_docs")
    end

    it "sets schema version to latest" do
      described_class.migrate!(path: tmp_db)
      db = described_class.connection(path: tmp_db)
      expect(described_class.current_version(db)).to eq(Personality::DB::SCHEMA_VERSION)
    end

    it "is idempotent" do
      described_class.migrate!(path: tmp_db)
      expect { described_class.migrate!(path: tmp_db) }.not_to raise_error
    end
  end

  describe ".current_version" do
    it "returns 0 for a fresh database" do
      fresh_db = File.join(Dir.tmpdir, "psn_db_fresh_#{$$}_#{rand(10000)}.db")
      described_class.connection(path: fresh_db)
      expect(described_class.current_version(described_class.connection(path: fresh_db))).to eq(0)
      described_class.reset!
      FileUtils.rm_f(fresh_db)
    end
  end

  describe ".transaction" do
    it "yields and commits" do
      described_class.migrate!(path: tmp_db)
      db = described_class.connection(path: tmp_db)

      described_class.transaction(path: tmp_db) do
        db.execute("INSERT INTO carts (tag) VALUES (?)", ["test"])
      end

      rows = db.execute("SELECT tag FROM carts")
      expect(rows.first["tag"]).to eq("test")
    end
  end

  describe ".reset!" do
    it "clears cached connections" do
      db1 = described_class.connection(path: tmp_db)
      described_class.reset!
      db2 = described_class.connection(path: tmp_db)
      expect(db1).not_to equal(db2)
    end
  end
end
