# frozen_string_literal: true

require "fileutils"
require "sqlite3"
require "sqlite_vec"

module Personality
  module DB
    DB_PATH = File.join(Dir.home, ".local", "share", "personality", "main.db")
    SCHEMA_VERSION = 2

    class << self
      def connection(path: nil)
        @connections ||= {}
        db_path = path || DB_PATH
        @connections[db_path] ||= open_connection(db_path)
      end

      def reset!
        @connections&.each_value(&:close)
        @connections = {}
      end

      def migrate!(path: nil)
        db = connection(path: path)
        current = current_version(db)
        return if current >= SCHEMA_VERSION

        apply_migrations(db, from: current)
      end

      def current_version(db = nil)
        db ||= connection
        row = db.execute("SELECT MAX(version) AS ver FROM schema_version").first
        row&.fetch("ver", 0) || 0
      rescue SQLite3::SQLException
        0
      end

      def transaction(path: nil, &block)
        connection(path: path).transaction(&block)
      end

      private

      def open_connection(db_path)
        FileUtils.mkdir_p(File.dirname(db_path))
        db = SQLite3::Database.new(db_path)
        db.results_as_hash = true
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA foreign_keys=ON")

        db.enable_load_extension(true)
        SqliteVec.load(db)
        db.enable_load_extension(false)

        db
      end

      def apply_migrations(db, from:)
        migrations.each do |version, sql|
          next if version <= from

          db.transaction do
            sql.each { |stmt| db.execute(stmt) }
            db.execute("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", [version])
          end
        end
      end

      def migrations
        {
          1 => [
            "CREATE TABLE IF NOT EXISTS schema_version (
              version INTEGER PRIMARY KEY,
              applied_at TEXT DEFAULT (datetime('now'))
            )"
          ],
          2 => [
            # Carts
            "CREATE TABLE IF NOT EXISTS carts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              tag TEXT UNIQUE NOT NULL,
              version TEXT,
              name TEXT,
              type TEXT,
              tagline TEXT,
              source TEXT,
              created_at TEXT DEFAULT (datetime('now')),
              updated_at TEXT DEFAULT (datetime('now'))
            )",

            # Memories
            "CREATE TABLE IF NOT EXISTS memories (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              cart_id INTEGER NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
              subject TEXT NOT NULL,
              content TEXT NOT NULL,
              metadata TEXT DEFAULT '{}',
              created_at TEXT DEFAULT (datetime('now')),
              updated_at TEXT DEFAULT (datetime('now'))
            )",
            "CREATE INDEX IF NOT EXISTS idx_memories_cart_id ON memories(cart_id)",
            "CREATE INDEX IF NOT EXISTS idx_memories_subject ON memories(subject)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
              memory_id INTEGER PRIMARY KEY,
              embedding float[768]
            )",

            # Code index
            "CREATE TABLE IF NOT EXISTS code_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL,
              content TEXT NOT NULL,
              language TEXT,
              project TEXT,
              chunk_index INTEGER DEFAULT 0,
              indexed_at TEXT DEFAULT (datetime('now'))
            )",
            "CREATE INDEX IF NOT EXISTS idx_code_chunks_project ON code_chunks(project)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS vec_code USING vec0(
              chunk_id INTEGER PRIMARY KEY,
              embedding float[768]
            )",

            # Doc index
            "CREATE TABLE IF NOT EXISTS doc_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL,
              content TEXT NOT NULL,
              project TEXT,
              chunk_index INTEGER DEFAULT 0,
              indexed_at TEXT DEFAULT (datetime('now'))
            )",
            "CREATE INDEX IF NOT EXISTS idx_doc_chunks_project ON doc_chunks(project)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS vec_docs USING vec0(
              chunk_id INTEGER PRIMARY KEY,
              embedding float[768]
            )",

            # Drop legacy table if migrating from v1
            "DROP TABLE IF EXISTS embeddings"
          ]
        }
      end
    end
  end
end
