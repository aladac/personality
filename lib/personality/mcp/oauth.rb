# frozen_string_literal: true

require "securerandom"
require "json"
require "openssl"
require "uri"

module Personality
  module MCP
    class OAuth
      # Static client credentials (set via env or generate once)
      CLIENT_ID = ENV.fetch("PSN_OAUTH_CLIENT_ID") { "psn-mcp-client" }
      CLIENT_SECRET = ENV.fetch("PSN_OAUTH_CLIENT_SECRET") { SecureRandom.hex(32) }

      # Token signing key
      TOKEN_SECRET = ENV.fetch("PSN_TOKEN_SECRET") { SecureRandom.hex(32) }

      attr_reader :base_url

      def initialize(base_url:)
        @base_url = base_url.chomp("/")
        @auth_codes = {} # code => { client_id:, redirect_uri:, code_challenge:, expires_at: }
        @tokens = {}     # token => { client_id:, expires_at: }
      end

      # GET /.well-known/oauth-protected-resource
      def protected_resource_metadata
        {
          resource: base_url,
          authorization_servers: [base_url],
          bearer_methods_supported: ["header"]
        }
      end

      # GET /.well-known/oauth-authorization-server
      def authorization_server_metadata
        {
          issuer: base_url,
          authorization_endpoint: "#{base_url}/authorize",
          token_endpoint: "#{base_url}/token",
          registration_endpoint: "#{base_url}/register",
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "client_credentials", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["client_secret_post", "none"]
        }
      end

      # POST /register - Dynamic client registration (simple version)
      def register(params)
        # For simplicity, just return our static client
        # A real implementation would create unique clients
        {
          client_id: CLIENT_ID,
          client_secret: CLIENT_SECRET,
          client_id_issued_at: Time.now.to_i,
          client_secret_expires_at: 0 # never expires
        }
      end

      # GET /authorize - Authorization endpoint
      def authorize(params)
        client_id = params["client_id"]
        redirect_uri = params["redirect_uri"]
        state = params["state"]
        code_challenge = params["code_challenge"]
        code_challenge_method = params["code_challenge_method"]
        response_type = params["response_type"]

        # Validate required params
        unless client_id && redirect_uri && response_type == "code"
          return { error: "invalid_request", error_description: "Missing required parameters" }
        end

        # Validate client (for now, accept our static client or any registered)
        # In production, validate against registered clients

        # Auto-approve (personal use) - generate authorization code
        code = SecureRandom.urlsafe_base64(32)
        @auth_codes[code] = {
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: code_challenge,
          code_challenge_method: code_challenge_method,
          expires_at: Time.now + 600 # 10 minutes
        }

        # Build redirect URL
        redirect = URI.parse(redirect_uri)
        query_params = URI.decode_www_form(redirect.query || "")
        query_params << ["code", code]
        query_params << ["state", state] if state
        redirect.query = URI.encode_www_form(query_params)

        { redirect_to: redirect.to_s }
      end

      # POST /token - Token endpoint
      def token(params)
        grant_type = params["grant_type"]

        case grant_type
        when "authorization_code"
          exchange_code(params)
        when "refresh_token"
          refresh_token(params)
        when "client_credentials"
          client_credentials(params)
        else
          { error: "unsupported_grant_type" }
        end
      end

      # Validate Bearer token from Authorization header
      def validate_token(auth_header)
        return nil unless auth_header&.start_with?("Bearer ")

        token = auth_header[7..]
        token_data = @tokens[token]

        return nil unless token_data
        return nil if Time.now > token_data[:expires_at]

        token_data
      end

      private

      def exchange_code(params)
        code = params["code"]
        client_id = params["client_id"]
        redirect_uri = params["redirect_uri"]
        code_verifier = params["code_verifier"]

        # Find and validate auth code
        auth_code = @auth_codes.delete(code)
        unless auth_code
          return { error: "invalid_grant", error_description: "Invalid or expired code" }
        end

        if Time.now > auth_code[:expires_at]
          return { error: "invalid_grant", error_description: "Code expired" }
        end

        if auth_code[:client_id] != client_id
          return { error: "invalid_grant", error_description: "Client mismatch" }
        end

        if auth_code[:redirect_uri] != redirect_uri
          return { error: "invalid_grant", error_description: "Redirect URI mismatch" }
        end

        # Validate PKCE
        if auth_code[:code_challenge]
          unless verify_pkce(code_verifier, auth_code[:code_challenge], auth_code[:code_challenge_method])
            return { error: "invalid_grant", error_description: "PKCE verification failed" }
          end
        end

        # Generate tokens
        generate_tokens(client_id)
      end

      def refresh_token(params)
        refresh = params["refresh_token"]
        # Simple refresh - just generate new tokens
        # In production, validate refresh token
        generate_tokens(params["client_id"] || "unknown")
      end

      def client_credentials(params)
        client_id = params["client_id"]
        client_secret = params["client_secret"]

        # Validate client credentials
        unless client_id == CLIENT_ID && client_secret == CLIENT_SECRET
          return { error: "invalid_client", error_description: "Invalid client credentials" }
        end

        generate_tokens(client_id)
      end

      def generate_tokens(client_id)
        access_token = SecureRandom.urlsafe_base64(32)
        refresh_token = SecureRandom.urlsafe_base64(32)
        expires_in = 3600 # 1 hour

        @tokens[access_token] = {
          client_id: client_id,
          expires_at: Time.now + expires_in
        }

        {
          access_token: access_token,
          token_type: "Bearer",
          expires_in: expires_in,
          refresh_token: refresh_token
        }
      end

      def verify_pkce(verifier, challenge, method)
        return false unless verifier && challenge

        case method
        when "S256"
          digest = OpenSSL::Digest::SHA256.digest(verifier)
          # URL-safe base64 without padding (RFC 7636)
          expected = [digest].pack("m0").tr("+/", "-_").delete("=")
          secure_compare(expected, challenge)
        when "plain", nil
          secure_compare(verifier, challenge)
        else
          false
        end
      end

      def secure_compare(a, b)
        return false if a.nil? || b.nil?
        return false if a.bytesize != b.bytesize
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end
    end
  end
end
