# frozen_string_literal: true

require_relative "db"

module Personality
  class Cart
    DEFAULT_TAG = "default"

    class << self
      def find_or_create(tag)
        db = DB.connection
        row = db.execute("SELECT * FROM carts WHERE tag = ?", [tag]).first

        if row
          row_to_hash(row)
        else
          db.execute(
            "INSERT INTO carts (tag) VALUES (?)", [tag]
          )
          id = db.last_insert_row_id
          {id: id, tag: tag}
        end
      end

      def active
        tag = ENV.fetch("PERSONALITY_CART", DEFAULT_TAG)
        find_or_create(tag)
      end

      def list
        db = DB.connection
        db.execute("SELECT * FROM carts ORDER BY tag").map { |row| row_to_hash(row) }
      end

      def use(tag)
        find_or_create(tag)
      end

      def create(tag, name: nil, type: nil, tagline: nil)
        db = DB.connection
        existing = db.execute("SELECT id FROM carts WHERE tag = ?", [tag]).first
        return find_or_create(tag) if existing

        db.execute(
          "INSERT INTO carts (tag, name, type, tagline) VALUES (?, ?, ?, ?)",
          [tag, name, type, tagline]
        )
        id = db.last_insert_row_id
        {id: id, tag: tag, name: name, type: type, tagline: tagline}
      end

      def find(tag)
        db = DB.connection
        row = db.execute("SELECT * FROM carts WHERE tag = ?", [tag]).first
        row ? row_to_hash(row) : nil
      end

      private

      def row_to_hash(row)
        {
          id: row["id"],
          tag: row["tag"],
          version: row["version"],
          name: row["name"],
          type: row["type"],
          tagline: row["tagline"],
          source: row["source"],
          created_at: row["created_at"],
          updated_at: row["updated_at"]
        }
      end
    end
  end
end
