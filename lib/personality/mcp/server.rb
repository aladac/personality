# frozen_string_literal: true

require "mcp"
require "mcp/transports/stdio"
require "json"
require_relative "../db"
require_relative "../memory"
require_relative "../indexer"
require_relative "../cart"

module Personality
  module MCP
    class Server
      def self.run
        DB.migrate!
        new.start
      end

      def initialize
        @server = ::MCP::Server.new(
          name: "core",
          version: Personality::VERSION
        )
        @server.server_context = {}
        register_tools
        register_resources
      end

      def start
        transport = ::MCP::Transports::StdioTransport.new(@server)
        transport.open
      end

      private

      def tool_response(result)
        ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
      end

      # === Memory Tools ===

      def register_memory_tools
        @server.define_tool(
          name: "memory.store",
          description: "Store a memory with subject and content. Automatically generates embedding.",
          input_schema: {
            type: "object",
            properties: {
              subject: {type: "string", description: "Memory subject/category"},
              content: {type: "string", description: "Memory content to store"},
              metadata: {type: "object", description: "Additional metadata"}
            },
            required: %w[subject content]
          }
        ) do |subject:, content:, server_context:, **opts|
          result = Memory.new.store(subject: subject, content: content, metadata: opts.fetch(:metadata, {}))
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "memory.recall",
          description: "Recall memories by semantic similarity to a query.",
          input_schema: {
            type: "object",
            properties: {
              query: {type: "string", description: "Query to search for"},
              limit: {type: "integer", description: "Max results (default: 5)"},
              subject: {type: "string", description: "Filter by subject"}
            },
            required: %w[query]
          }
        ) do |query:, server_context:, **opts|
          result = Memory.new.recall(query: query, limit: opts.fetch(:limit, 5), subject: opts[:subject])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "memory.search",
          description: "Search memories by subject or metadata.",
          input_schema: {
            type: "object",
            properties: {
              subject: {type: "string", description: "Subject to search"},
              limit: {type: "integer", description: "Max results"}
            }
          }
        ) do |server_context:, **opts|
          result = Memory.new.search(subject: opts[:subject], limit: opts.fetch(:limit, 20))
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "memory.forget",
          description: "Delete a memory by ID.",
          input_schema: {
            type: "object",
            properties: {
              id: {type: "integer", description: "Memory ID to delete"}
            },
            required: %w[id]
          }
        ) do |id:, server_context:, **|
          result = Memory.new.forget(id: id)
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "memory.list",
          description: "List all memory subjects and counts.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          result = Memory.new.list
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end

      # === Index Tools ===

      def register_index_tools
        @server.define_tool(
          name: "index.code",
          description: "Index code files in a directory for semantic search.",
          input_schema: {
            type: "object",
            properties: {
              path: {type: "string", description: "Directory path to index"},
              project: {type: "string", description: "Project name for grouping"},
              extensions: {type: "array", items: {type: "string"}, description: "File extensions to include"}
            },
            required: %w[path]
          }
        ) do |path:, server_context:, **opts|
          result = Indexer.new.index_code(path: path, project: opts[:project], extensions: opts[:extensions])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "index.docs",
          description: "Index documentation files for semantic search.",
          input_schema: {
            type: "object",
            properties: {
              path: {type: "string", description: "Directory path to index"},
              project: {type: "string", description: "Project name"}
            },
            required: %w[path]
          }
        ) do |path:, server_context:, **opts|
          result = Indexer.new.index_docs(path: path, project: opts[:project])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "index.search",
          description: "Search indexed code and docs by semantic similarity.",
          input_schema: {
            type: "object",
            properties: {
              query: {type: "string", description: "Search query"},
              type: {type: "string", enum: %w[code docs all], description: "What to search"},
              project: {type: "string", description: "Filter by project"},
              limit: {type: "integer", description: "Max results"}
            },
            required: %w[query]
          }
        ) do |query:, server_context:, **opts|
          result = Indexer.new.search(
            query: query,
            type: (opts[:type] || "all").to_sym,
            project: opts[:project],
            limit: opts.fetch(:limit, 10)
          )
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "index.status",
          description: "Show indexing status and statistics.",
          input_schema: {
            type: "object",
            properties: {
              project: {type: "string", description: "Filter by project"}
            }
          }
        ) do |server_context:, **opts|
          result = Indexer.new.status(project: opts[:project])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "index.clear",
          description: "Clear index for a project or all.",
          input_schema: {
            type: "object",
            properties: {
              project: {type: "string", description: "Project to clear (omit for all)"},
              type: {type: "string", enum: %w[code docs all], description: "What to clear"}
            }
          }
        ) do |server_context:, **opts|
          result = Indexer.new.clear(project: opts[:project], type: (opts[:type] || "all").to_sym)
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end

      # === Cart Tools ===

      def register_cart_tools
        @server.define_tool(
          name: "cart.list",
          description: "List all personas.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          result = {carts: Cart.list}
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "cart.use",
          description: "Switch active persona.",
          input_schema: {
            type: "object",
            properties: {
              tag: {type: "string", description: "Persona tag"}
            },
            required: %w[tag]
          }
        ) do |tag:, server_context:, **|
          result = Cart.use(tag)
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end

        @server.define_tool(
          name: "cart.create",
          description: "Create a new persona.",
          input_schema: {
            type: "object",
            properties: {
              tag: {type: "string", description: "Persona tag"},
              name: {type: "string", description: "Display name"},
              type: {type: "string", description: "Persona type"}
            },
            required: %w[tag]
          }
        ) do |tag:, server_context:, **opts|
          result = Cart.create(tag, name: opts[:name], type: opts[:type])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end

      # === Persona Tools ===

      def register_persona_tools
        @server.define_tool(
          name: "cart.teach",
          description: "Learn a persona from a training YAML file. Creates a .pcart cartridge and imports memories into the database.",
          input_schema: {
            type: "object",
            properties: {
              training_file: {type: "string", description: "Path to the training YAML file"}
            },
            required: %w[training_file]
          }
        ) do |training_file:, server_context:, **|
          require_relative "../cart_manager"
          manager = Personality::CartManager.new
          cart = manager.create_from_training(training_file)
          result = manager.import_memories(cart)
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({
            tag: cart.tag,
            name: cart.name,
            version: cart.version,
            memory_count: cart.memory_count,
            voice: cart.voice,
            cart_path: cart.path,
            imported: result
          })}])
        end

        @server.define_tool(
          name: "cart.show",
          description: "Show persona details and LLM instructions for a cartridge.",
          input_schema: {
            type: "object",
            properties: {
              tag: {type: "string", description: "Persona tag (e.g. bt7274). If omitted, shows active cart."}
            }
          }
        ) do |server_context:, **opts|
          require_relative "../cart_manager"
          require_relative "../persona_builder"
          manager = Personality::CartManager.new
          tag = opts[:tag]

          if tag
            path = File.join(manager.carts_dir, "#{tag.downcase}.pcart")
            raise "Cart not found: #{tag}" unless File.exist?(path)
          else
            carts = manager.list_carts
            raise "No carts found" if carts.empty?
            path = carts.first
          end

          cart = manager.load_cart(path)
          builder = Personality::PersonaBuilder.new
          identity = cart.preferences&.identity

          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({
            tag: cart.tag,
            name: cart.name,
            version: cart.version,
            type: identity&.type,
            source: identity&.source,
            tagline: identity&.tagline,
            voice: cart.voice,
            memory_count: cart.memory_count,
            summary: builder.build_summary(cart),
            instructions: builder.build_instructions(cart)
          })}])
        end

        @server.define_tool(
          name: "cart.instructions",
          description: "Get the LLM persona instructions for the active or specified cart. Returns markdown formatted character instructions.",
          input_schema: {
            type: "object",
            properties: {
              tag: {type: "string", description: "Persona tag (optional, uses first available if omitted)"}
            }
          }
        ) do |server_context:, **opts|
          require_relative "../cart_manager"
          require_relative "../persona_builder"
          manager = Personality::CartManager.new
          tag = opts[:tag]

          if tag
            path = File.join(manager.carts_dir, "#{tag.downcase}.pcart")
            raise "Cart not found: #{tag}" unless File.exist?(path)
          else
            carts = manager.list_carts
            raise "No carts found" if carts.empty?
            path = carts.first
          end

          cart = manager.load_cart(path)
          builder = Personality::PersonaBuilder.new
          instructions = builder.build_instructions(cart)

          ::MCP::Tool::Response.new([{type: "text", text: instructions}])
        end

        @server.define_tool(
          name: "cart.carts",
          description: "List available .pcart cartridge files with their metadata.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          require_relative "../cart_manager"
          manager = Personality::CartManager.new
          carts = manager.list_carts.map { |p| manager.cart_info(p).merge(path: p) }
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({carts: carts})}])
        end
      end

      # === Resources ===

      def register_resources
        resources = [
          ::MCP::Resource.new(
            uri: "memory://subjects",
            name: "memory-subjects",
            description: "All memory subjects with counts",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "memory://stats",
            name: "memory-stats",
            description: "Total memories, subjects, date range",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "memory://recent",
            name: "memory-recent",
            description: "Most recent 10 memories",
            mime_type: "application/json"
          )
        ]
        @server.resources = resources

        @server.resources_read_handler do |params|
          uri = params[:uri]
          result = read_memory_resource(uri)
          [{uri: uri, mimeType: "application/json", text: JSON.generate(result)}]
        end
      end

      def register_tools
        register_memory_tools
        register_index_tools
        register_cart_tools
        register_persona_tools
      end

      def read_memory_resource(uri)
        db = DB.connection
        cart = Cart.active

        case uri
        when "memory://subjects"
          rows = db.execute("SELECT subject, COUNT(*) AS count FROM memories WHERE cart_id = ? GROUP BY subject ORDER BY count DESC", [cart[:id]])
          {subjects: rows.map { |r| {subject: r["subject"], count: r["count"]} }}

        when "memory://stats"
          total = db.execute("SELECT COUNT(*) AS c FROM memories WHERE cart_id = ?", [cart[:id]]).dig(0, "c") || 0
          subjects = db.execute("SELECT COUNT(DISTINCT subject) AS c FROM memories WHERE cart_id = ?", [cart[:id]]).dig(0, "c") || 0
          dates = db.execute("SELECT MIN(created_at) AS oldest, MAX(created_at) AS newest FROM memories WHERE cart_id = ?", [cart[:id]]).first
          {cart: cart[:tag], total_memories: total, total_subjects: subjects, oldest: dates&.fetch("oldest", nil), newest: dates&.fetch("newest", nil)}

        when "memory://recent"
          rows = db.execute("SELECT id, subject, content, created_at FROM memories WHERE cart_id = ? ORDER BY created_at DESC LIMIT 10", [cart[:id]])
          {memories: rows.map { |r| {id: r["id"], subject: r["subject"], content: r["content"], created_at: r["created_at"]} }}

        else
          {error: "Unknown resource: #{uri}"}
        end
      end
    end
  end
end
