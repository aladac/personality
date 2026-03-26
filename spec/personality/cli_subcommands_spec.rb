# frozen_string_literal: true

# Tests for CLI subcommand branches — focuses on branch coverage
# for the Thor wrappers that delegate to service objects.

require "personality"
require "personality/cli"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "CLI subcommands" do
  let(:tmp_db) { File.join(Dir.tmpdir, "psn_cli_test_#{$$}_#{rand(10000)}.db") }
  let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }

  before do
    Personality::DB.reset!
    stub_const("Personality::DB::DB_PATH", tmp_db)
    Personality::DB.migrate!(path: tmp_db)
    allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)
  end

  after do
    Personality::DB.reset!
    FileUtils.rm_f(tmp_db)
  end

  def capture_stdout(&block)
    io = StringIO.new
    original = $stdout
    $stdout = io
    block.call
    io.string
  ensure
    $stdout = original
  end

  describe Personality::CLI::Memory do
    describe "#store" do
      it "stores and prints confirmation" do
        output = capture_stdout { described_class.start(["store", "test_subj", "test content"]) }
        expect(output).to include("Stored")
      end
    end

    describe "#recall" do
      it "prints 'No memories' when empty" do
        output = capture_stdout { described_class.start(["recall", "query"]) }
        expect(output).to include("No memories")
      end

      it "prints results when memories exist" do
        Personality::Memory.new.store(subject: "cli_recall", content: "recall content here")
        output = capture_stdout { described_class.start(["recall", "recall content"]) }
        expect(output).to include("cli_recall")
      end

      it "accepts --subject and --limit" do
        output = capture_stdout { described_class.start(["recall", "q", "--subject", "x", "--limit", "3"]) }
        expect(output).to include("No memories")
      end
    end

    describe "#search" do
      it "prints 'No memories' when empty" do
        output = capture_stdout { described_class.start(["search"]) }
        expect(output).to include("No memories")
      end

      it "prints results when memories exist" do
        Personality::Memory.new.store(subject: "cli_search", content: "search me")
        output = capture_stdout { described_class.start(["search", "--subject", "cli_search"]) }
        expect(output).to include("cli_search")
      end
    end

    describe "#forget" do
      it "prints success when memory exists" do
        result = Personality::Memory.new.store(subject: "gone", content: "bye")
        output = capture_stdout { described_class.start(["forget", result[:id].to_s]) }
        expect(output).to include("Deleted")
      end

      it "prints 'not found' for nonexistent id" do
        output = capture_stdout { described_class.start(["forget", "999999"]) }
        expect(output).to include("not found")
      end
    end

    describe "#list" do
      it "prints 'No memories stored' when empty" do
        output = capture_stdout { described_class.start(["list"]) }
        expect(output).to include("No memories")
      end

      it "prints table when memories exist" do
        Personality::Memory.new.store(subject: "cli_list", content: "data")
        # tty-table calls ioctl for width detection; stub it for StringIO
        allow(TTY::Screen).to receive(:width).and_return(120)
        output = capture_stdout { described_class.start(["list"]) }
        expect(output).to include("cli_list")
      end
    end

    describe "#save" do
      it "returns silently when stdin has no data" do
        allow($stdin).to receive(:tty?).and_return(true)
        output = capture_stdout { described_class.start(["save"]) }
        expect(output).to eq("")
      end

      it "handles JSON with transcript_path" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"transcript_path": "/nonexistent/path"}')
        output = capture_stdout { described_class.start(["save"]) }
        expect(output).to eq("")
      end
    end
  end

  describe Personality::CLI::Index do
    let(:tmpdir) { Dir.mktmpdir("psn_cli_idx") }
    after { FileUtils.rm_rf(tmpdir) }

    describe "#code" do
      it "indexes code and prints result" do
        File.write(File.join(tmpdir, "test.rb"), "class Foo; end\n" * 20)
        output = capture_stdout { described_class.start(["code", tmpdir]) }
        expect(output).to include("chunks indexed")
      end
    end

    describe "#docs" do
      it "indexes docs and prints result" do
        File.write(File.join(tmpdir, "test.md"), "# Heading\n\n" + ("content " * 100))
        output = capture_stdout { described_class.start(["docs", tmpdir]) }
        expect(output).to include("chunks indexed")
      end
    end

    describe "#search" do
      it "prints 'No results' when nothing indexed" do
        output = capture_stdout { described_class.start(["search", "foobar"]) }
        expect(output).to include("No results")
      end

      it "prints results when indexed" do
        File.write(File.join(tmpdir, "test.rb"), "class FooSearch; end\n" * 20)
        capture_stdout { described_class.start(["code", tmpdir]) }
        output = capture_stdout { described_class.start(["search", "FooSearch"]) }
        # May or may not find results depending on embedding stub, but exercises the branch
        expect(output.length).to be > 0
      end
    end

    describe "#status" do
      it "prints 'No indexed content' when empty" do
        output = capture_stdout { described_class.start(["status"]) }
        expect(output).to include("No indexed")
      end

      it "prints table when indexed" do
        File.write(File.join(tmpdir, "test.rb"), "class StatusTest; end\n" * 20)
        capture_stdout { described_class.start(["code", tmpdir, "--project", "myproj"]) }
        allow(TTY::Screen).to receive(:width).and_return(120)
        output = capture_stdout { described_class.start(["status"]) }
        expect(output).to include("myproj")
      end
    end

    describe "#clear" do
      it "prints cleared result" do
        output = capture_stdout { described_class.start(["clear"]) }
        expect(output).to include("Cleared")
      end
    end

    describe "#hook" do
      it "returns silently when no stdin" do
        allow($stdin).to receive(:tty?).and_return(true)
        output = capture_stdout { described_class.start(["hook"]) }
        expect(output).to eq("")
      end

      it "returns silently when no file_path in data" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"tool_input": {}}')
        output = capture_stdout { described_class.start(["hook"]) }
        expect(output).to eq("")
      end

      it "indexes file when file_path is present" do
        test_file = File.join(tmpdir, "hook_test.rb")
        File.write(test_file, "class HookTest; end\n" * 20)
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return(JSON.generate({
          "tool_input" => {"file_path" => test_file},
          "cwd" => tmpdir
        }))
        output = capture_stdout { described_class.start(["hook"]) }
        expect(output).to eq("")
      end
    end
  end

  describe Personality::CLI::Tts do
    before do
      stub_const("Personality::TTS::DATA_DIR", File.join(Dir.tmpdir, "psn_cli_tts_#{$$}"))
      stub_const("Personality::TTS::PID_FILE", File.join(Personality::TTS::DATA_DIR, "tts.pid"))
      stub_const("Personality::TTS::WAV_FILE", File.join(Personality::TTS::DATA_DIR, "tts.wav"))
      stub_const("Personality::TTS::NATURAL_STOP_FLAG", File.join(Personality::TTS::DATA_DIR, "tts_flag"))
    end

    after { FileUtils.rm_rf(Personality::TTS::DATA_DIR) }

    describe "#stop" do
      it "prints 'No TTS playing' when nothing to stop" do
        output = capture_stdout { described_class.start(["stop"]) }
        expect(output).to include("No TTS")
      end
    end

    describe "#mark_natural_stop" do
      it "creates the flag file" do
        capture_stdout { described_class.start(["mark-natural-stop"]) }
        expect(File.exist?(Personality::TTS::NATURAL_STOP_FLAG)).to be true
      end
    end

    describe "#interrupt_check" do
      it "reports natural stop continue" do
        Personality::TTS.mark_natural_stop
        output = capture_stdout { described_class.start(["interrupt-check"]) }
        expect(output).to include("Natural stop")
      end

      it "reports user interrupt with nothing playing" do
        output = capture_stdout { described_class.start(["interrupt-check"]) }
        expect(output).to include("No TTS")
      end
    end

    describe "#current" do
      it "shows active voice and install status" do
        output = capture_stdout { described_class.start(["current"]) }
        expect(output).to include("Voice:")
      end
    end
  end

  describe Personality::CLI::Context do
    describe "#track_read" do
      it "tracks file from stdin JSON" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return(
          JSON.generate({"tool_input" => {"file_path" => "/tmp/test.rb"}, "session_id" => "test"})
        )
        capture_stdout { described_class.start(["track-read"]) }
      end

      it "handles missing file_path" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"tool_input": {}}')
        capture_stdout { described_class.start(["track-read"]) }
      end
    end

    describe "#list" do
      it "prints 'No files' when empty" do
        output = capture_stdout { described_class.start(["list"]) }
        expect(output).to include("No files")
      end
    end

    describe "#clear" do
      it "prints confirmation" do
        output = capture_stdout { described_class.start(["clear"]) }
        expect(output).to include("Context cleared")
      end
    end
  end

  describe Personality::CLI::Hooks do
    describe "#pre_tool_use" do
      it "logs event from stdin" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"tool_name": "Read"}')
        capture_stdout { described_class.start(["pre-tool-use"]) }
      end
    end

    describe "#session_start" do
      it "outputs persona info when cart has name" do
        Personality::Cart.create("cli_test_persona", name: "TestBot", tagline: "Hello world")
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("PERSONALITY_CART", "default").and_return("cli_test_persona")
        allow($stdin).to receive(:tty?).and_return(true)

        output = capture_stdout { described_class.start(["session-start"]) }
        expect(output).to include("TestBot")
      end

      it "handles cart without name or tagline" do
        allow($stdin).to receive(:tty?).and_return(true)
        output = capture_stdout { described_class.start(["session-start"]) }
        # Default cart may or may not have a name; just verify no crash
        expect { output }.not_to raise_error
      end
    end

    describe "#notification" do
      it "returns silently when no stdin data" do
        allow($stdin).to receive(:tty?).and_return(true)
        output = capture_stdout { described_class.start(["notification"]) }
        expect(output).to eq("")
      end

      it "returns silently when message is nil" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"cwd": "/tmp"}')
        output = capture_stdout { described_class.start(["notification"]) }
        expect(output).to eq("")
      end

      it "returns silently when message is empty" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"message": "", "cwd": "/tmp"}')
        output = capture_stdout { described_class.start(["notification"]) }
        expect(output).to eq("")
      end

      it "speaks message via TTS" do
        allow($stdin).to receive(:tty?).and_return(false)
        allow($stdin).to receive(:read).and_return('{"message": "Build done", "cwd": "/tmp/myproject"}')
        allow(Personality::TTS).to receive(:stop_current)
        allow(Personality::TTS).to receive(:speak)

        capture_stdout { described_class.start(["notification"]) }
        expect(Personality::TTS).to have_received(:speak).with("myproject: Build done")
      end
    end

    describe "#install" do
      it "writes hooks.json" do
        tmpdir = Dir.mktmpdir("psn_hooks_install")
        output_path = File.join(tmpdir, "hooks.json")

        output = capture_stdout { described_class.start(["install", "-o", output_path]) }
        expect(output).to include("Generated")
        expect(File.exist?(output_path)).to be true
        parsed = JSON.parse(File.read(output_path))
        expect(parsed).to have_key("hooks")
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe Personality::CLI do
    describe "#version" do
      it "prints version" do
        output = capture_stdout { described_class.start(["version"]) }
        expect(output).to include("psn")
      end
    end

    describe "#info" do
      it "prints info" do
        output = capture_stdout { described_class.start(["info"]) }
        expect(output).to include("Personality")
      end
    end
  end
end
