# frozen_string_literal: true

require "rack"
require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "server"
require_relative "oauth"

module Personality
  module MCP
    class RackApp
      ALLOWED_ORIGINS = %w[
        https://claude.ai
        https://console.anthropic.com
      ].freeze

      def initialize(base_url: nil)
        @base_url = base_url || ENV.fetch("PSN_BASE_URL", "https://psn.saiden.dev")
        @oauth = OAuth.new(base_url: @base_url)
        @server = build_server
        @transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(@server, stateless: true)
      end

      def call(env)
        request = Rack::Request.new(env)
        origin = env["HTTP_ORIGIN"]

        # Debug logging
        warn "[MCP] #{request.request_method} #{request.path_info} Origin: #{origin.inspect}"

        # Handle CORS preflight
        if request.options?
          return cors_preflight_response(request)
        end

        # Route OAuth endpoints
        case request.path_info
        when "/.well-known/oauth-protected-resource"
          return json_response(@oauth.protected_resource_metadata, origin)

        when "/.well-known/oauth-authorization-server"
          return json_response(@oauth.authorization_server_metadata, origin)

        when "/register"
          if request.post?
            params = parse_body(request)
            return json_response(@oauth.register(params), origin)
          end

        when "/authorize"
          if request.get?
            params = request.params
            result = @oauth.authorize(params)
            if result[:redirect_to]
              return [302, {"Location" => result[:redirect_to]}, []]
            else
              return json_response(result, origin, status: 400)
            end
          end

        when "/token"
          if request.post?
            params = parse_body(request)
            auth_header = env["HTTP_AUTHORIZATION"]
            result = @oauth.token(params, auth_header: auth_header)
            status = result[:error] ? 400 : 200
            return json_response(result, origin, status: status)
          end
        end

        # Handle MCP endpoint at /mcp or root /
        unless request.path_info == "/" || request.path_info == "/mcp"
          return [404, add_cors_headers({"Content-Type" => "application/json"}, origin), ['{"error":"Not found"}']]
        end

        # For MCP endpoints, validate Bearer token
        auth_header = env["HTTP_AUTHORIZATION"]
        unless @oauth.validate_token(auth_header)
          # Return 401 to trigger OAuth flow
          return [401, add_cors_headers({"Content-Type" => "application/json", "WWW-Authenticate" => "Bearer"}, origin), ['{"error":"Unauthorized"}']]
        end

        # Validate Origin (DNS rebinding protection)
        unless valid_origin?(origin)
          return [403, {"Content-Type" => "application/json"}, ['{"error":"Invalid origin"}']]
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
        # HTTP server defaults to :core mode (no indexer - that runs locally)
        mode = ENV.fetch("PSN_MCP_MODE", "core").to_sym
        server = Server.new(mode: mode)
        server.instance_variable_get(:@server)
      end

      def parse_body(request)
        body = request.body.read
        request.body.rewind
        return {} if body.empty?

        content_type = request.content_type || ""
        if content_type.include?("application/json")
          JSON.parse(body)
        else
          # application/x-www-form-urlencoded
          URI.decode_www_form(body).to_h
        end
      rescue JSON::ParserError
        {}
      end

      def json_response(data, origin, status: 200)
        headers = add_cors_headers({"Content-Type" => "application/json"}, origin)
        [status, headers, [JSON.generate(data)]]
      end

      def cors_preflight_response(request)
        origin = request.env["HTTP_ORIGIN"]
        headers = {
          "Access-Control-Allow-Origin" => valid_origin?(origin) ? origin : "",
          "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
          "Access-Control-Allow-Headers" => "Content-Type, Accept, Authorization, X-API-Key, Mcp-Session-Id, MCP-Protocol-Version",
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
    end
  end
end
