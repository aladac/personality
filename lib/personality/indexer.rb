# frozen_string_literal: true

require "json"
require_relative "db"
require_relative "embedding"
require_relative "chunker"

module Personality
  class Indexer
    CODE_EXTENSIONS = %w[.py .rs .rb .js .ts .go .java .c .cpp .h].to_set.freeze
    DOC_EXTENSIONS = %w[.md .txt .rst .adoc].to_set.freeze

    def index_code(path:, project: nil, extensions: nil)
      dir = File.expand_path(path)
      proj = project || File.basename(dir)
      exts = extensions ? extensions.map { |e| e.start_with?(".") ? e : ".#{e}" }.to_set : CODE_EXTENSIONS

      index_files(dir, proj, exts, table: "code_chunks", vec_table: "vec_code", language: true)
    end

    def index_docs(path:, project: nil)
      dir = File.expand_path(path)
      proj = project || File.basename(dir)

      index_files(dir, proj, DOC_EXTENSIONS, table: "doc_chunks", vec_table: "vec_docs", language: false)
    end

    def search(query:, type: :all, project: nil, limit: 10)
      embedding = Embedding.generate(query)
      return {results: []} if embedding.empty?

      results = []
      db = DB.connection

      if type == :all || type == :code
        results.concat(
          search_table(db, "code_chunks", "vec_code", embedding, project: project, limit: limit, type: :code)
        )
      end

      if type == :all || type == :docs
        results.concat(
          search_table(db, "doc_chunks", "vec_docs", embedding, project: project, limit: limit, type: :docs)
        )
      end

      results.sort_by! { |r| r[:distance] }
      {results: results.first(limit)}
    end

    def status(project: nil)
      db = DB.connection

      code_stats = count_by_project(db, "code_chunks", project)
      doc_stats = count_by_project(db, "doc_chunks", project)

      {code_index: code_stats, doc_index: doc_stats}
    end

    def clear(project: nil, type: :all)
      db = DB.connection

      if type == :all || type == :code
        clear_table(db, "code_chunks", "vec_code", project)
      end

      if type == :all || type == :docs
        clear_table(db, "doc_chunks", "vec_docs", project)
      end

      {cleared: type.to_s, project: project || "all"}
    end

    def index_single_file(file_path:, project: nil)
      path = File.expand_path(file_path)
      return unless File.exist?(path)

      ext = File.extname(path).downcase
      proj = project || File.basename(Dir.pwd)

      if CODE_EXTENSIONS.include?(ext)
        index_one_file(path, proj, "code_chunks", "vec_code", language: ext[1..])
      elsif DOC_EXTENSIONS.include?(ext)
        index_one_file(path, proj, "doc_chunks", "vec_docs", language: nil)
      end
    end

    private

    def index_files(dir, project, extensions, table:, vec_table:, language:)
      indexed = 0
      errors = []

      Dir.glob(File.join(dir, "**", "*")).each do |file_path|
        next unless File.file?(file_path)
        next unless extensions.include?(File.extname(file_path).downcase)

        begin
          lang = language ? File.extname(file_path).downcase[1..] : nil
          count = index_one_file(file_path, project, table, vec_table, language: lang)
          indexed += count
        rescue => e
          errors << "#{file_path}: #{e.message}"
        end
      end

      {indexed: indexed, project: project, errors: errors.first(5)}
    end

    def index_one_file(file_path, project, table, vec_table, language: nil)
      content = File.read(file_path, encoding: "UTF-8")
      return 0 if content.length < Chunker::MIN_LENGTH

      db = DB.connection
      chunks = Chunker.split(content)
      count = 0

      # Remove old chunks for this file
      old_ids = db.execute(
        "SELECT id FROM #{table} WHERE path = ? AND project = ?", [file_path, project]
      ).map { |r| r["id"] }

      old_ids.each do |id|
        db.execute("DELETE FROM #{vec_table} WHERE chunk_id = ?", [id])
        db.execute("DELETE FROM #{table} WHERE id = ?", [id])
      end

      chunks.each_with_index do |chunk, idx|
        embedding = Embedding.generate(chunk)
        next if embedding.empty?

        if language
          db.execute(
            "INSERT INTO #{table} (path, content, language, project, chunk_index) VALUES (?, ?, ?, ?, ?)",
            [file_path, chunk, language, project, idx]
          )
        else
          db.execute(
            "INSERT INTO #{table} (path, content, project, chunk_index) VALUES (?, ?, ?, ?)",
            [file_path, chunk, project, idx]
          )
        end

        chunk_id = db.last_insert_row_id
        db.execute(
          "INSERT INTO #{vec_table} (chunk_id, embedding) VALUES (?, ?)",
          [chunk_id, embedding.to_json]
        )
        count += 1
      end

      count
    end

    def search_table(db, table, vec_table, embedding, project:, limit:, type:)
      if project
        rows = db.execute(<<~SQL, [embedding.to_json, limit, project])
          SELECT c.id, c.path, c.content, c.project, v.distance
          FROM #{vec_table} v
          INNER JOIN #{table} c ON c.id = v.chunk_id
          WHERE v.embedding MATCH ? AND k = ?
            AND c.project = ?
          ORDER BY v.distance
        SQL
      else
        rows = db.execute(<<~SQL, [embedding.to_json, limit])
          SELECT c.id, c.path, c.content, c.project, v.distance
          FROM #{vec_table} v
          INNER JOIN #{table} c ON c.id = v.chunk_id
          WHERE v.embedding MATCH ? AND k = ?
          ORDER BY v.distance
        SQL
      end

      rows.map do |r|
        {
          type: type,
          id: r["id"],
          path: r["path"],
          content: r["content"]&.slice(0, 500),
          project: r["project"],
          distance: r["distance"]
        }
      end
    end

    def count_by_project(db, table, project)
      if project
        db.execute(
          "SELECT project, COUNT(*) AS count FROM #{table} WHERE project = ? GROUP BY project",
          [project]
        )
      else
        db.execute("SELECT project, COUNT(*) AS count FROM #{table} GROUP BY project")
      end.map { |r| {project: r["project"], count: r["count"]} }
    end

    def clear_table(db, table, vec_table, project)
      if project
        ids = db.execute("SELECT id FROM #{table} WHERE project = ?", [project]).map { |r| r["id"] }
        ids.each do |id|
          db.execute("DELETE FROM #{vec_table} WHERE chunk_id = ?", [id])
        end
        db.execute("DELETE FROM #{table} WHERE project = ?", [project])
      else
        db.execute("DELETE FROM #{vec_table}")
        db.execute("DELETE FROM #{table}")
      end
    end
  end
end
