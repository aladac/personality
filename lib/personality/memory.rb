# frozen_string_literal: true

require "json"
require_relative "db"
require_relative "embedding"
require_relative "cart"

module Personality
  class Memory
    attr_reader :cart_id

    def initialize(cart_id: nil)
      @cart_id = cart_id || Cart.active[:id]
    end

    def store(subject:, content:, metadata: {})
      db = DB.connection
      embedding = Embedding.generate(content)

      db.execute(
        "INSERT INTO memories (cart_id, subject, content, metadata) VALUES (?, ?, ?, ?)",
        [cart_id, subject, content, JSON.generate(metadata)]
      )
      memory_id = db.last_insert_row_id

      unless embedding.empty?
        db.execute(
          "INSERT INTO vec_memories (memory_id, embedding) VALUES (?, ?)",
          [memory_id, embedding.to_json]
        )
      end

      {id: memory_id, subject: subject}
    end

    def recall(query:, limit: 5, subject: nil)
      embedding = Embedding.generate(query)
      return {memories: []} if embedding.empty?

      db = DB.connection

      rows = if subject
        db.execute(<<~SQL, [embedding.to_json, limit, cart_id, subject])
          SELECT m.id, m.subject, m.content, m.metadata, m.created_at, v.distance
          FROM vec_memories v
          INNER JOIN memories m ON m.id = v.memory_id
          WHERE v.embedding MATCH ? AND k = ?
            AND m.cart_id = ? AND m.subject = ?
          ORDER BY v.distance
        SQL
      else
        db.execute(<<~SQL, [embedding.to_json, limit, cart_id])
          SELECT m.id, m.subject, m.content, m.metadata, m.created_at, v.distance
          FROM vec_memories v
          INNER JOIN memories m ON m.id = v.memory_id
          WHERE v.embedding MATCH ? AND k = ?
            AND m.cart_id = ?
          ORDER BY v.distance
        SQL
      end

      memories = rows.map { |r| memory_row_to_hash(r) }
      {memories: memories}
    end

    def search(subject: nil, limit: 20)
      db = DB.connection

      rows = if subject
        db.execute(
          "SELECT id, subject, content, created_at FROM memories WHERE cart_id = ? AND subject LIKE ? ORDER BY created_at DESC LIMIT ?",
          [cart_id, "%#{subject}%", limit]
        )
      else
        db.execute(
          "SELECT id, subject, content, created_at FROM memories WHERE cart_id = ? ORDER BY created_at DESC LIMIT ?",
          [cart_id, limit]
        )
      end

      memories = rows.map do |r|
        {id: r["id"], subject: r["subject"], content: r["content"], created_at: r["created_at"]}
      end
      {memories: memories}
    end

    def forget(id:)
      db = DB.connection
      db.execute("DELETE FROM vec_memories WHERE memory_id = ?", [id])
      db.execute("DELETE FROM memories WHERE id = ? AND cart_id = ?", [id, cart_id])
      deleted = db.changes > 0
      {deleted: deleted}
    end

    def list
      db = DB.connection
      rows = db.execute(
        "SELECT subject, COUNT(*) AS count FROM memories WHERE cart_id = ? GROUP BY subject ORDER BY count DESC",
        [cart_id]
      )
      subjects = rows.map { |r| {subject: r["subject"], count: r["count"]} }
      {subjects: subjects}
    end

    private

    def memory_row_to_hash(row)
      {
        id: row["id"],
        subject: row["subject"],
        content: row["content"],
        metadata: safe_parse_json(row["metadata"]),
        created_at: row["created_at"],
        distance: row["distance"]
      }
    end

    def safe_parse_json(str)
      return {} if str.nil? || str.empty?
      JSON.parse(str)
    rescue JSON::ParserError
      {}
    end
  end
end
