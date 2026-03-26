# frozen_string_literal: true

require "json"
require "fileutils"

module Personality
  module Hooks
    LOG_DIR = File.join(Dir.home, ".config", "psn")
    LOG_FILE = File.join(LOG_DIR, "hooks.jsonl")
    CONFIG_FILE = File.join(LOG_DIR, "logging.toml")

    DEFAULT_MAX_LENGTH = 50
    DEFAULT_PRESERVE_FIELDS = %w[path file_path cwd transcript_path file directory].freeze
    DEFAULT_PRESERVE_SUFFIXES = %w[_path _dir].freeze

    HOOKS_JSON_TEMPLATE = {
      hooks: {
        PreToolUse: [{hooks: [{type: "command", command: "psn hooks pre-tool-use", timeout: 5000}]}],
        PostToolUse: [
          {matcher: "Read", hooks: [{type: "command", command: "psn context track-read", timeout: 5000}]},
          {matcher: "Write|Edit", hooks: [{type: "command", command: "psn index hook", timeout: 30_000}]}
        ],
        Stop: [{hooks: [
          {type: "command", command: "psn tts mark-natural-stop", timeout: 1000},
          {type: "command", command: "psn memory save", timeout: 5000}
        ]}],
        SubagentStop: [{hooks: [{type: "command", command: "psn hooks subagent-stop", timeout: 5000}]}],
        SessionStart: [{hooks: [{type: "command", command: "psn hooks session-start", timeout: 5000}]}],
        SessionEnd: [{hooks: [
          {type: "command", command: "psn hooks session-end", timeout: 5000},
          {type: "command", command: "psn tts stop", timeout: 1000}
        ]}],
        UserPromptSubmit: [{hooks: [
          {type: "command", command: "psn hooks user-prompt-submit", timeout: 5000},
          {type: "command", command: "psn tts interrupt-check", timeout: 1000}
        ]}],
        PreCompact: [{hooks: [{type: "command", command: "psn memory save", timeout: 5000}]}],
        Notification: [{hooks: [{type: "command", command: "psn hooks notification", timeout: 5000}]}]
      }
    }.freeze

    class << self
      def log(event, data = nil)
        FileUtils.mkdir_p(LOG_DIR)

        entry = {
          ts: Time.now.utc.iso8601,
          event: event,
          session: ENV.fetch("CLAUDE_SESSION_ID", ""),
          cwd: Dir.pwd
        }

        if data.is_a?(Hash)
          data.each do |key, value|
            next if key.to_s == "hook_event_name"
            entry[key.to_sym] = process_value(key.to_s, value)
          end
        end

        File.open(LOG_FILE, "a") { |f| f.puts(JSON.generate(entry)) }
      rescue
        nil # Silent fail — don't break hooks on logging errors
      end

      def read_stdin_json
        return nil if $stdin.tty?
        JSON.parse($stdin.read)
      rescue JSON::ParserError, EOFError
        nil
      end

      def generate_hooks_json
        JSON.pretty_generate(HOOKS_JSON_TEMPLATE)
      end

      def truncate(value, max_length: nil)
        max = max_length || config[:max_length]
        return value if value.length <= max
        "#{value[0, max - 3]}..."
      end

      def preserved_key?(key)
        key_lower = key.downcase
        return true if config[:preserve_fields].include?(key_lower)
        config[:preserve_suffixes].any? { |suffix| key_lower.end_with?(suffix) }
      end

      def process_value(key, value)
        case value
        when nil then nil
        when true, false then value
        when Integer, Float then value
        when String
          preserved_key?(key) ? value : truncate(value)
        when Hash
          value.transform_keys(&:to_s).each_with_object({}) do |(k, v), h|
            h[k] = process_value(k, v)
          end
        when Array
          processed = value.first(5).map { |item| process_value(key, item) }
          processed << "...+#{value.length - 5} more" if value.length > 5
          processed
        else
          truncate(value.to_s)
        end
      end

      def config
        @config ||= load_config
      end

      def reset_config!
        @config = nil
      end

      private

      def load_config
        cfg = {
          max_length: DEFAULT_MAX_LENGTH,
          preserve_fields: DEFAULT_PRESERVE_FIELDS.dup,
          preserve_suffixes: DEFAULT_PRESERVE_SUFFIXES.dup
        }

        if File.exist?(CONFIG_FILE)
          begin
            require "toml-rb"
            file_config = TomlRB.load_file(CONFIG_FILE)
            if (t = file_config["truncation"])
              cfg[:max_length] = t["max_length"] if t["max_length"]
              cfg[:preserve_fields] = t["preserve_fields"] if t["preserve_fields"]
              cfg[:preserve_suffixes] = t["preserve_suffixes"] if t["preserve_suffixes"]
            end
          rescue
            # Use defaults on error
          end
        end

        cfg
      end
    end
  end
end
