# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Index < Thor
      desc "code PATH", "Index code files in a directory"
      option :project, type: :string, desc: "Project name"
      def code(path)
        require_relative "../indexer"
        require_relative "../db"
        require "pastel"
        require "tty-spinner"

        DB.migrate!
        pastel = Pastel.new
        spinner = TTY::Spinner.new("  :spinner Indexing code...", format: :dots)
        spinner.auto_spin

        result = Personality::Indexer.new.index_code(path: path, project: options[:project])

        spinner.success(pastel.green("done"))
        puts "  #{pastel.bold(result[:project])}: #{result[:indexed]} chunks indexed"
        if result[:errors].any?
          puts pastel.yellow("  Errors (#{result[:errors].length}):")
          result[:errors].each { |e| puts "    #{e}" }
        end
      end

      desc "docs PATH", "Index documentation files"
      option :project, type: :string, desc: "Project name"
      def docs(path)
        require_relative "../indexer"
        require_relative "../db"
        require "pastel"
        require "tty-spinner"

        DB.migrate!
        pastel = Pastel.new
        spinner = TTY::Spinner.new("  :spinner Indexing docs...", format: :dots)
        spinner.auto_spin

        result = Personality::Indexer.new.index_docs(path: path, project: options[:project])

        spinner.success(pastel.green("done"))
        puts "  #{pastel.bold(result[:project])}: #{result[:indexed]} chunks indexed"
        if result[:errors].any?
          puts pastel.yellow("  Errors (#{result[:errors].length}):")
          result[:errors].each { |e| puts "    #{e}" }
        end
      end

      desc "search QUERY", "Semantic search across indexed code and docs"
      option :type, type: :string, default: "all", desc: "Search type: code, docs, all"
      option :project, type: :string, desc: "Filter by project"
      option :limit, type: :numeric, default: 10, desc: "Max results"
      def search(query)
        require_relative "../indexer"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        pastel = Pastel.new
        type = options[:type].to_sym

        result = Personality::Indexer.new.search(
          query: query, type: type, project: options[:project], limit: options[:limit]
        )

        if result[:results].empty?
          puts pastel.dim("No results found")
          return
        end

        result[:results].each do |r|
          puts "#{pastel.cyan(r[:type].to_s)} #{pastel.bold(r[:path])} #{pastel.dim("(dist: #{r[:distance]&.round(4)})")}"
          puts "  #{r[:content]&.slice(0, 150)}"
          puts
        end
      end

      desc "status", "Show indexing statistics"
      option :project, type: :string, desc: "Filter by project"
      def status
        require_relative "../indexer"
        require_relative "../db"
        require "pastel"
        require "tty-table"

        DB.migrate!
        pastel = Pastel.new
        result = Personality::Indexer.new.status(project: options[:project])

        all_stats = result[:code_index].map { |s| [s[:project], s[:count], "code"] } +
          result[:doc_index].map { |s| [s[:project], s[:count], "docs"] }

        if all_stats.empty?
          puts pastel.dim("No indexed content")
          return
        end

        table = TTY::Table.new(
          header: %w[Project Chunks Type],
          rows: all_stats
        )
        puts table.render(:unicode, padding: [0, 1])
      end

      desc "clear", "Clear indexed content"
      option :project, type: :string, desc: "Project to clear (omit for all)"
      option :type, type: :string, default: "all", desc: "What to clear: code, docs, all"
      def clear
        require_relative "../indexer"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        result = Personality::Indexer.new.clear(project: options[:project], type: options[:type].to_sym)
        puts Pastel.new.green("Cleared #{result[:cleared]} for #{result[:project]}")
      end

      desc "hook", "Re-index a file (PostToolUse hook, reads JSON from stdin)"
      def hook
        require_relative "../indexer"
        require_relative "../hooks"
        require_relative "../db"

        DB.migrate!
        data = Personality::Hooks.read_stdin_json
        return unless data

        file_path = data.dig("tool_input", "file_path")
        return unless file_path

        cwd = data["cwd"] || Dir.pwd
        project = File.basename(cwd)

        Personality::Indexer.new.index_single_file(file_path: file_path, project: project)
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
