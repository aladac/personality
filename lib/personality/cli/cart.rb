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

      desc "teach FILE", "Learn a persona from a training YAML file"
      option :output, type: :string, aliases: "-o", desc: "Output .pcart path"
      option :import, type: :boolean, default: true, desc: "Import memories into database"
      def teach(file)
        require_relative "../cart_manager"
        require_relative "../db"
        require "pastel"
        require "tty-spinner"

        pastel = Pastel.new
        manager = CartManager.new

        # Parse and create .pcart
        spinner = TTY::Spinner.new("  :spinner Parsing training file...", format: :dots)
        spinner.auto_spin
        cart = manager.create_from_training(file, output_path: options[:output])
        spinner.success(pastel.green("#{cart.name} — #{cart.memory_count} memories"))

        puts "  #{pastel.dim("Tag:")} #{cart.tag}"
        puts "  #{pastel.dim("Version:")} #{cart.version}" unless cart.version.to_s.empty?
        puts "  #{pastel.dim("Voice:")} #{cart.voice}" if cart.voice && !cart.voice.empty?
        puts "  #{pastel.dim("Cart:")} #{cart.path}"

        # Import memories into DB
        if options[:import]
          spinner = TTY::Spinner.new("  :spinner Importing memories...", format: :dots)
          spinner.auto_spin
          result = manager.import_memories(cart)
          spinner.success(pastel.green("#{result[:stored]} stored, #{result[:skipped]} skipped"))
        end

        # Show persona instructions preview
        require_relative "../persona_builder"
        builder = PersonaBuilder.new
        summary = builder.build_summary(cart)
        puts "\n  #{pastel.bold(summary)}"
        puts "  #{pastel.dim("Run `psn cart show #{cart.tag}` for full instructions")}"
      end

      desc "teach-all DIR", "Learn all personas from a training directory"
      option :force, type: :boolean, default: false, aliases: "-f", desc: "Overwrite existing carts"
      def teach_all(dir)
        require_relative "../cart_manager"
        require_relative "../training_parser"
        require_relative "../db"
        require "pastel"

        pastel = Pastel.new
        parser = TrainingParser.new
        manager = CartManager.new

        files = parser.list_files(dir)
        if files.empty?
          puts pastel.dim("No training files found in #{dir}")
          return
        end

        puts pastel.bold("Found #{files.size} training files\n")

        files.each do |file|
          tag = File.basename(file, ".*").downcase
          cart_path = File.join(manager.carts_dir, "#{tag}.pcart")

          if File.exist?(cart_path) && !options[:force]
            puts "  #{pastel.yellow("skip")} #{tag} (already exists, use --force)"
            next
          end

          begin
            cart = manager.create_from_training(file)
            result = manager.import_memories(cart)
            puts "  #{pastel.green("✓")} #{cart.name} — #{cart.memory_count} memories (#{result[:stored]} new)"
          rescue => e
            puts "  #{pastel.red("✗")} #{File.basename(file)} — #{e.message}"
          end
        end
      end

      desc "show [TAG]", "Show persona details and instructions"
      option :memories, type: :boolean, default: false, aliases: "-m", desc: "Show raw memories"
      option :instructions, type: :boolean, default: false, aliases: "-i", desc: "Show full LLM instructions"
      def show(tag = nil)
        require_relative "../cart_manager"
        require_relative "../persona_builder"
        require "pastel"

        pastel = Pastel.new
        manager = CartManager.new

        # Find the cart
        if tag
          path = File.join(manager.carts_dir, "#{tag.downcase}.pcart")
          unless File.exist?(path)
            puts pastel.red("Cart not found: #{tag}")
            return
          end
        else
          carts = manager.list_carts
          if carts.empty?
            puts pastel.dim("No carts found. Run `psn cart teach <file>` first.")
            return
          end
          path = carts.first
        end

        cart = manager.load_cart(path)
        builder = PersonaBuilder.new
        identity = cart.preferences&.identity

        puts pastel.bold(builder.build_summary(cart))
        puts ""
        puts "  #{pastel.dim("Tag:")} #{cart.tag}"
        puts "  #{pastel.dim("Version:")} #{cart.version}" unless cart.version.to_s.empty?
        puts "  #{pastel.dim("Name:")} #{identity.full_name}" if identity && !identity.full_name.empty?
        puts "  #{pastel.dim("Type:")} #{identity.type}" if identity && !identity.type.empty?
        puts "  #{pastel.dim("Source:")} #{identity.source}" if identity && !identity.source.empty?
        puts "  #{pastel.dim("Tagline:")} #{identity.tagline}" if identity && !identity.tagline.empty?
        puts "  #{pastel.dim("Voice:")} #{cart.voice}" if cart.voice && !cart.voice.empty?
        puts "  #{pastel.dim("Memories:")} #{cart.memory_count}"
        puts "  #{pastel.dim("Cart:")} #{cart.path}"

        if options[:memories]
          puts "\n#{pastel.bold("Memories:")}\n\n"
          cart.memories.each do |m|
            puts "  #{pastel.cyan(m.subject)}"
            puts "    #{m.content}\n\n"
          end
        end

        if options[:instructions]
          puts "\n#{pastel.bold("LLM Instructions:")}\n\n"
          puts builder.build_instructions(cart)
        end
      end

      desc "carts", "List available .pcart files"
      def carts
        require_relative "../cart_manager"
        require "pastel"
        require "tty-table"

        pastel = Pastel.new
        manager = CartManager.new

        carts = manager.list_carts
        if carts.empty?
          puts pastel.dim("No .pcart files found. Run `psn cart teach <file>` first.")
          return
        end

        rows = carts.map do |path|
          info = manager.cart_info(path)
          [
            info[:tag] || File.basename(path, ".pcart"),
            info[:version] || "-",
            info[:memory_count]&.to_s || "?",
            File.size(path) > 1024 ? "#{(File.size(path) / 1024.0).round(1)} KB" : "#{File.size(path)} B"
          ]
        end

        table = TTY::Table.new(
          header: %w[Tag Version Memories Size],
          rows: rows
        )
        puts table.render(:unicode, padding: [0, 1])
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
