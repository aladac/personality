# frozen_string_literal: true

require "rack"
require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "server"

module Personality
  module MCP
    class RackApp
      ALLOWED_ORIGINS = %w[
        https://claude.ai
        https://console.anthropic.com
      ].freeze

      def initialize(api_key: nil)
        @api_key = api_key || ENV["PSN_API_KEY"]
        @server = build_server
        @transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(@server)
      end

      def call(env)
        request = Rack::Request.new(env)
        origin = env["HTTP_ORIGIN"]

        # Handle CORS preflight
        if request.options?
          return cors_preflight_response(request)
        end

        # Handle OAuth discovery endpoints (return 404 - no OAuth)
        if request.path_info.start_with?("/.well-known/oauth")
          return [404, add_cors_headers({"Content-Type" => "application/json"}, origin), ['{"error":"OAuth not supported"}']]
        end

        # Handle /register endpoint (return 404 - no dynamic registration)
        if request.path_info == "/register"
          return [404, add_cors_headers({"Content-Type" => "application/json"}, origin), ['{"error":"Registration not supported"}']]
        end

        # Validate Origin (DNS rebinding protection)
        unless valid_origin?(origin)
          return [403, {"Content-Type" => "application/json"}, ['{"error":"Invalid origin"}']]
        end

        # API key auth
        if @api_key
          provided_key = env["HTTP_X_API_KEY"]
          unless secure_compare(@api_key, provided_key.to_s)
            return [401, {"Content-Type" => "application/json"}, ['{"error":"Unauthorized"}']]
          end
        end

        # Delegate to MCP transport
        status, headers, body = @transport.handle_request(request)

        # Add CORS headers to response
        headers = add_cors_headers(headers, origin)

        [status, headers, body]
      end

      private

      def build_server
        DB.migrate!
        server = Server.new
        server.instance_variable_get(:@server)
      end

      def cors_preflight_response(request)
        origin = request.env["HTTP_ORIGIN"]
        headers = {
          "Access-Control-Allow-Origin" => valid_origin?(origin) ? origin : "",
          "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
          "Access-Control-Allow-Headers" => "Content-Type, Accept, X-API-Key, Mcp-Session-Id, MCP-Protocol-Version",
          "Access-Control-Max-Age" => "86400"
        }
        [204, headers, []]
      end

      def add_cors_headers(headers, origin)
        headers = headers.dup
        if valid_origin?(origin)
          headers["Access-Control-Allow-Origin"] = origin
          headers["Access-Control-Expose-Headers"] = "Mcp-Session-Id"
        end
        headers
      end

      def valid_origin?(origin)
        return true if origin.nil? # Non-browser clients
        return true if origin.start_with?("http://localhost", "http://127.0.0.1")
        ALLOWED_ORIGINS.include?(origin)
      end

      def secure_compare(a, b)
        return false if a.empty? || b.empty?
        return false if a.bytesize != b.bytesize
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end
    end
  end
end
