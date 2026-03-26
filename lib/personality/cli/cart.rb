# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Cart < Thor
      desc "list", "List all personas"
      def list
        require_relative "../cart"
        require_relative "../db"
        require "pastel"
        require "tty-table"

        DB.migrate!
        pastel = Pastel.new
        carts = Personality::Cart.list

        if carts.empty?
          puts pastel.dim("No personas found")
          return
        end

        table = TTY::Table.new(
          header: %w[ID Tag Name Type],
          rows: carts.map { |c| [c[:id], c[:tag], c[:name] || "-", c[:type] || "-"] }
        )
        puts table.render(:unicode, padding: [0, 1])
      end

      desc "use TAG", "Switch active persona"
      def use(tag)
        require_relative "../cart"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        cart = Personality::Cart.use(tag)
        puts "#{Pastel.new.green("Active:")} #{cart[:tag]} (id: #{cart[:id]})"
      end

      desc "create TAG", "Create a new persona"
      option :name, type: :string, desc: "Display name"
      option :type, type: :string, desc: "Persona type"
      option :tagline, type: :string, desc: "Short description"
      def create(tag)
        require_relative "../cart"
        require_relative "../db"
        require "pastel"

        DB.migrate!
        cart = Personality::Cart.create(tag, name: options[:name], type: options[:type], tagline: options[:tagline])
        puts "#{Pastel.new.green("Created:")} #{cart[:tag]} (id: #{cart[:id]})"
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
