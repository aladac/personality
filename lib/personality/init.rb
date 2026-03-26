# frozen_string_literal: true

require "open3"
require "fileutils"
require "pastel"
require "tty-spinner"
require_relative "db"

module Personality
  class Init
    DB_PATH = DB::DB_PATH

    attr_reader :pastel, :auto_yes

    def initialize(auto_yes: false)
      @pastel = Pastel.new
      @auto_yes = auto_yes
    end

    def run
      puts pastel.bold("Personality Init")
      puts pastel.dim("=" * 40)
      puts

      results = []
      results << setup_database
      results << check_ollama
      results << check_nomic_embed
      results << check_uv
      results << check_piper

      puts
      puts pastel.bold("Summary")
      puts pastel.dim("-" * 40)
      results.each { |label, status| print_result(label, status) }
      puts
    end

    private

    # Step 1: Create sqlite-vec database
    def setup_database
      label = "sqlite-vec database"
      puts pastel.bold("\n1. #{label}")

      if File.exist?(DB_PATH)
        puts "  #{pastel.green("exists")} #{DB_PATH}"
        return [label, :exists]
      end

      unless confirm?("Create database at #{DB_PATH}?")
        return [label, :skipped]
      end

      spinner = spin("Creating database")
      begin
        DB.migrate!
        spinner.success(pastel.green("done"))
        [label, :installed]
      rescue => e
        spinner.error(pastel.red("failed"))
        puts "  #{pastel.red(e.message)}"
        [label, :failed]
      end
    end

    # Step 2: Check for Ollama
    def check_ollama
      label = "ollama"
      puts pastel.bold("\n2. #{label}")

      version = command_version("ollama", "--version")
      if version
        puts "  #{pastel.green("found")} #{version}"
        @ollama_was_present = true
        ensure_ollama_running
        return [label, :exists]
      end

      @ollama_was_present = false
      install_cmd = brew_available? ? "brew install ollama" : "curl -fsSL https://ollama.com/install.sh | sh"

      unless confirm?("Ollama not found. Install via `#{install_cmd}`?")
        return [label, :skipped]
      end

      spinner = spin("Installing ollama")
      if run_command(install_cmd)
        spinner.success(pastel.green("done"))
        ensure_ollama_running
        [label, :installed]
      else
        spinner.error(pastel.red("failed"))
        [label, :failed]
      end
    end

    # Step 3: Install nomic-embed-text model
    def check_nomic_embed
      label = "nomic-embed-text"
      puts pastel.bold("\n3. #{label}")

      unless command_exists?("ollama")
        puts "  #{pastel.yellow("skipped")} ollama not available"
        return [label, :skipped]
      end

      if model_installed?("nomic-embed-text")
        puts "  #{pastel.green("found")} nomic-embed-text"
        return [label, :exists]
      end

      # Auto-pull if ollama was just installed, otherwise prompt
      unless @ollama_was_present == false || confirm?("Pull nomic-embed-text model?")
        return [label, :skipped]
      end

      spinner = spin("Pulling nomic-embed-text")
      if run_command("ollama pull nomic-embed-text")
        spinner.success(pastel.green("done"))
        [label, :installed]
      else
        spinner.error(pastel.red("failed"))
        [label, :failed]
      end
    end

    # Step 4a: Check for uv
    def check_uv
      label = "uv"
      puts pastel.bold("\n4a. #{label}")

      version = command_version("uv", "--version")
      if version
        puts "  #{pastel.green("found")} #{version}"
        return [label, :exists]
      end

      install_cmd = brew_available? ? "brew install uv" : "curl -LsSf https://astral.sh/uv/install.sh | sh"

      unless confirm?("uv not found. Install via `#{install_cmd}`?")
        return [label, :skipped]
      end

      spinner = spin("Installing uv")
      if run_command(install_cmd)
        spinner.success(pastel.green("done"))
        [label, :installed]
      else
        spinner.error(pastel.red("failed"))
        [label, :failed]
      end
    end

    # Step 4: Install piper-tts
    def check_piper
      label = "piper-tts"
      puts pastel.bold("\n4b. #{label}")

      version = command_version("piper", "--help")
      if version
        puts "  #{pastel.green("found")} piper"
        return [label, :exists]
      end

      uv_bin = find_executable("uv")
      unless uv_bin
        puts "  #{pastel.yellow("skipped")} uv not available"
        return [label, :skipped]
      end

      unless confirm?("piper-tts not found. Install via `uv tool install`?")
        return [label, :skipped]
      end

      spinner = spin("Installing piper-tts")
      if run_command("#{uv_bin} tool install piper-tts --with pathvalidate")
        spinner.success(pastel.green("done"))
        [label, :installed]
      else
        spinner.error(pastel.red("failed"))
        [label, :failed]
      end
    end

    # Helpers

    def confirm?(message)
      return true if auto_yes

      print "  #{message} #{pastel.dim("[Y/n]")} "
      response = $stdin.gets&.strip&.downcase
      response.empty? || response == "y" || response == "yes"
    end

    def spin(message)
      TTY::Spinner.new("  :spinner #{message}...", format: :dots)
        .tap(&:auto_spin)
    end

    def command_exists?(cmd)
      _, status = Open3.capture2e("which", cmd)
      status.success?
    end

    def command_version(cmd, flag)
      stdout, status = Open3.capture2e(cmd, flag)
      status.success? ? stdout.strip.lines.first&.strip : nil
    rescue Errno::ENOENT
      nil
    end

    def find_executable(cmd)
      path, status = Open3.capture2e("which", cmd)
      status.success? ? path.strip : nil
    end

    def run_command(cmd)
      _, status = Open3.capture2e(cmd)
      status.success?
    end

    def brew_available?
      command_exists?("brew")
    end

    def model_installed?(name)
      stdout, status = Open3.capture2e("ollama", "list")
      return false unless status.success?

      stdout.lines.any? { |line| line.include?(name) }
    rescue Errno::ENOENT
      false
    end

    def ensure_ollama_running
      _, status = Open3.capture2e("ollama", "list")
      return if status.success?

      puts "  #{pastel.yellow("starting")} ollama serve"
      spawn("ollama serve", [:out, :err] => "/dev/null")
      sleep 2
    rescue Errno::ENOENT
      nil
    end

    def print_result(label, status)
      icon = case status
      when :exists then pastel.green("[OK]")
      when :installed then pastel.cyan("[INSTALLED]")
      when :skipped then pastel.yellow("[SKIPPED]")
      when :failed then pastel.red("[FAILED]")
      end
      puts "  #{icon} #{label}"
    end
  end
end
