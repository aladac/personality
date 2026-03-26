# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Memory < Thor
      desc "store SUBJECT CONTENT", "Store a memory"
      def store(subject, content)
        require_relative "../memory"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        result = Personality::Memory.new.store(subject: subject, content: content)
        puts "#{Pastel.new.green("Stored:")} #{result[:subject]} (id: #{result[:id]})"
      end

      desc "recall QUERY", "Recall memories by semantic similarity"
      option :limit, type: :numeric, default: 5, desc: "Max results"
      option :subject, type: :string, desc: "Filter by subject"
      def recall(query)
        require_relative "../memory"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        result = Personality::Memory.new.recall(
          query: query, limit: options[:limit], subject: options[:subject]
        )
        pastel = Pastel.new

        if result[:memories].empty?
          puts pastel.dim("No memories found")
          return
        end

        result[:memories].each do |m|
          puts "#{pastel.cyan("##{m[:id]}")} #{pastel.bold(m[:subject])} #{pastel.dim("(dist: #{m[:distance]&.round(4)})") if m[:distance]}"
          puts "  #{m[:content][0, 200]}"
          puts
        end
      end

      desc "search", "Search memories by subject"
      option :subject, type: :string, desc: "Filter by subject"
      option :limit, type: :numeric, default: 20, desc: "Max results"
      def search
        require_relative "../memory"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        result = Personality::Memory.new.search(subject: options[:subject], limit: options[:limit])
        pastel = Pastel.new

        if result[:memories].empty?
          puts pastel.dim("No memories found")
          return
        end

        result[:memories].each do |m|
          puts "#{pastel.cyan("##{m[:id]}")} #{pastel.bold(m[:subject])}"
          puts "  #{m[:content][0, 200]}"
          puts
        end
      end

      desc "forget ID", "Delete a memory"
      def forget(id)
        require_relative "../memory"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        result = Personality::Memory.new.forget(id: id.to_i)
        pastel = Pastel.new
        if result[:deleted]
          puts pastel.green("Deleted memory ##{id}")
        else
          puts pastel.yellow("Memory ##{id} not found")
        end
      end

      desc "list", "List memory subjects"
      def list
        require_relative "../memory"
        require_relative "../db"
        require "pastel"
        require "tty-table"

        DB.migrate!
        result = Personality::Memory.new.list
        pastel = Pastel.new

        if result[:subjects].empty?
          puts pastel.dim("No memories stored")
          return
        end

        table = TTY::Table.new(
          header: %w[Subject Count],
          rows: result[:subjects].map { |s| [s[:subject], s[:count]] }
        )
        puts table.render(:unicode, padding: [0, 1])
      end

      desc "save", "Save memories from Stop hook (reads JSON from stdin)"
      def save
        require_relative "../memory"
        require_relative "../hooks"
        require_relative "../db"

        DB.migrate!
        data = Personality::Hooks.read_stdin_json
        return unless data

        transcript_path = data["transcript_path"]
        nil unless transcript_path && File.exist?(transcript_path)

        # Extract learnings from transcript — placeholder for future implementation
        # For now, this is a no-op hook endpoint
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
