# frozen_string_literal: true

require "json"
require "fileutils"

module Personality
  module Context
    TRACKING_DIR = File.join(ENV.fetch("TMPDIR", "/tmp"), "psn-context")

    class << self
      def track_read(file_path, session_id: nil)
        return if file_path.nil? || file_path.empty?

        sid = session_id || current_session_id
        ctx = load(sid)
        return if ctx[:files].include?(file_path)

        ctx[:files] << file_path

        # Also track resolved path for robustness
        resolved = File.expand_path(file_path)
        ctx[:files] << resolved if resolved != file_path && !ctx[:files].include?(resolved)

        save(sid, ctx)
      end

      def check(file_path, session_id: nil)
        sid = session_id || current_session_id
        ctx = load(sid)
        abs_path = File.expand_path(file_path)
        ctx[:files].include?(file_path) || ctx[:files].include?(abs_path)
      end

      def list(session_id: nil)
        sid = session_id || current_session_id
        ctx = load(sid)
        ctx[:files]
      end

      def clear(session_id: nil)
        sid = session_id || current_session_id
        path = tracking_file(sid)
        File.delete(path) if File.exist?(path)
      end

      def load(session_id)
        path = tracking_file(session_id)
        return {files: []} unless File.exist?(path)

        data = JSON.parse(File.read(path))
        {files: data.fetch("files", [])}
      rescue JSON::ParserError
        {files: []}
      end

      def current_session_id
        ENV.fetch("CLAUDE_SESSION_ID", "default")
      end

      private

      def tracking_file(session_id)
        FileUtils.mkdir_p(TRACKING_DIR)
        File.join(TRACKING_DIR, "#{session_id}.json")
      end

      def save(session_id, context)
        path = tracking_file(session_id)
        File.write(path, JSON.generate({files: context[:files]}))
      end
    end
  end
end
