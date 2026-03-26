# frozen_string_literal: true

require "personality"
require "personality/cart_manager"
require "tmpdir"
require "fileutils"
require "zip"
require "yaml"
require "json"

RSpec.describe Personality::CartManager do
  let(:tmpdir) { Dir.mktmpdir("psn_cartmgr_test") }
  let(:carts_dir) { File.join(tmpdir, "carts") }
  let(:training_dir) { File.join(tmpdir, "training") }
  let(:manager) { described_class.new(carts_dir: carts_dir, training_dir: training_dir) }

  before { FileUtils.mkdir_p([carts_dir, training_dir]) }
  after { FileUtils.rm_rf(tmpdir) }

  def create_pcart(tag, memories: [], preferences: {}, version: "1.0", include_prefs_yml: true)
    path = File.join(carts_dir, "#{tag}.pcart")
    persona = {"tag" => tag, "version" => version, "memories" => memories}

    Zip::OutputStream.open(path) do |zos|
      zos.put_next_entry("persona.yml")
      zos.write(YAML.dump(persona))
      if include_prefs_yml
        zos.put_next_entry("preferences.yml")
        zos.write(YAML.dump(preferences))
      end
    end
    path
  end

  describe "#load_cart" do
    it "loads tag, version, memories, and preferences" do
      path = create_pcart("bot",
        memories: [{"subject" => "self.name", "content" => "Bot"}],
        preferences: {"identity" => {"name" => "Bot", "type" => "ai"}},
        version: "2.0")

      cart = manager.load_cart(path)
      expect(cart.tag).to eq("bot")
      expect(cart.version).to eq("2.0")
      expect(cart.memories.size).to eq(1)
      expect(cart.memories.first.subject).to eq("self.name")
      expect(cart.name).to eq("Bot")
      expect(cart.preferences.identity.type).to eq("ai")
    end

    it "raises for nonexistent file" do
      expect { manager.load_cart("/no/such.pcart") }.to raise_error(Errno::ENOENT)
    end

    it "raises for missing persona.yml" do
      path = File.join(carts_dir, "bad.pcart")
      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("other.txt")
        zos.write("nope")
      end

      expect { manager.load_cart(path) }.to raise_error(ArgumentError, /Missing persona\.yml/)
    end

    it "handles cart without preferences.yml" do
      path = create_pcart("minimal", include_prefs_yml: false)
      cart = manager.load_cart(path)
      expect(cart.tag).to eq("minimal")
      expect(cart.preferences).to be_a(Personality::PreferencesConfig)
    end

    it "merges embedded preferences from persona.yml" do
      path = File.join(carts_dir, "embedded.pcart")
      persona = {"tag" => "embedded", "memories" => [],
                 "preferences" => {"identity" => {"name" => "Embedded"}}}

      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(YAML.dump(persona))
      end

      cart = manager.load_cart(path)
      expect(cart.preferences.identity.name).to eq("Embedded")
    end

    it "does not overwrite preferences.yml keys with embedded prefs" do
      path = File.join(carts_dir, "priority.pcart")
      persona = {"tag" => "p", "memories" => [],
                 "preferences" => {"identity" => {"name" => "Embedded", "type" => "embedded_type"}}}
      prefs = {"identity" => {"name" => "FromPrefsFile"}}

      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(YAML.dump(persona))
        zos.put_next_entry("preferences.yml")
        zos.write(YAML.dump(prefs))
      end

      cart = manager.load_cart(path)
      # preferences.yml wins for keys it defines
      expect(cart.preferences.identity.name).to eq("FromPrefsFile")
    end

    it "handles array content in memories" do
      path = create_pcart("arr", memories: [{"subject" => "x", "content" => %w[A B]}])
      cart = manager.load_cart(path)
      expect(cart.memories.first.content).to eq("A, B")
    end

    it "skips invalid memory entries" do
      path = create_pcart("skip", memories: [
        {"subject" => "valid", "content" => "ok"},
        "not_a_hash",
        {"subject" => "no_content"},
        {"content" => "no_subject"}
      ])

      cart = manager.load_cart(path)
      expect(cart.memories.size).to eq(1)
    end

    it "falls back to filename for missing tag" do
      path = File.join(carts_dir, "fallback.pcart")
      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(YAML.dump({"memories" => []}))
      end

      cart = manager.load_cart(path)
      expect(cart.tag).to eq("fallback")
    end

    it "handles non-hash embedded preferences" do
      path = File.join(carts_dir, "badprefs.pcart")
      persona = {"tag" => "bp", "memories" => [], "preferences" => "not a hash"}

      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(YAML.dump(persona))
      end

      cart = manager.load_cart(path)
      expect(cart.tag).to eq("bp")
    end
  end

  describe "#save_cart" do
    it "saves to default carts_dir path" do
      cart = Personality::Cartridge.new(
        path: nil, tag: "saved", version: "1.0",
        memories: [Personality::TrainingMemory.new(subject: "t", content: "d")],
        preferences: Personality::PreferencesConfig.from_hash({"identity" => {"name" => "Saved"}})
      )

      result = manager.save_cart(cart)
      expect(result).to eq(File.join(carts_dir, "saved.pcart"))
      expect(File.exist?(result)).to be true

      loaded = manager.load_cart(result)
      expect(loaded.tag).to eq("saved")
      expect(loaded.memories.size).to eq(1)
    end

    it "saves to a custom path" do
      cart = Personality::Cartridge.new(
        path: nil, tag: "custom", version: "1.0", memories: [],
        preferences: Personality::PreferencesConfig.from_hash({})
      )

      custom = File.join(tmpdir, "nested", "dir", "custom.pcart")
      result = manager.save_cart(cart, path: custom)
      expect(result).to eq(custom)
      expect(File.exist?(custom)).to be true
    end
  end

  describe "#create_from_training" do
    before do
      allow(Personality::Embedding).to receive(:generate)
        .and_return(Array.new(768) { rand(-1.0..1.0) })
    end

    it "creates a .pcart from a training YAML" do
      path = File.join(training_dir, "bot.yml")
      File.write(path, <<~YAML)
        tag: trainbot
        version: "3.0"
        preferences:
          identity:
            name: TrainBot
            type: trainer
        memories:
          - subject: self.trait
            content: helpful
      YAML

      cart = manager.create_from_training(path)
      expect(cart.tag).to eq("trainbot")
      expect(cart.version).to eq("3.0")
      expect(cart.name).to eq("TrainBot")
      expect(cart.memory_count).to eq(1)
      expect(File.exist?(cart.path)).to be true
    end

    it "uses filename as tag when tag is empty" do
      path = File.join(training_dir, "notagbot.yml")
      File.write(path, "memories:\n  - subject: x\n    content: y\n")

      cart = manager.create_from_training(path)
      expect(cart.tag).to eq("notagbot")
    end

    it "saves to custom output path" do
      path = File.join(training_dir, "out.yml")
      File.write(path, "tag: outbot\nmemories:\n  - subject: a\n    content: b\n")

      output = File.join(tmpdir, "output.pcart")
      cart = manager.create_from_training(path, output_path: output)
      expect(cart.path).to eq(output)
    end
  end

  describe "#import_memories" do
    let(:tmp_db) { File.join(tmpdir, "test.db") }
    let(:fake_embedding) { Array.new(768) { rand(-1.0..1.0) } }

    before do
      Personality::DB.reset!
      stub_const("Personality::DB::DB_PATH", tmp_db)
      Personality::DB.migrate!(path: tmp_db)
      allow(Personality::Embedding).to receive(:generate).and_return(fake_embedding)
    end

    after { Personality::DB.reset! }

    it "imports memories and returns counts" do
      cart = Personality::Cartridge.new(
        tag: "imp", version: "1.0",
        memories: [
          Personality::TrainingMemory.new(subject: "trait.1", content: "kind"),
          Personality::TrainingMemory.new(subject: "trait.2", content: "brave")
        ],
        preferences: Personality::PreferencesConfig.from_hash(
          {"identity" => {"name" => "Imp", "type" => "bot", "tagline" => "Hi"}}
        )
      )

      result = manager.import_memories(cart)
      expect(result[:stored]).to eq(2)
      expect(result[:skipped]).to eq(0)
      expect(result[:total]).to eq(2)
      expect(result[:cart_id]).to be_a(Integer)
    end

    it "skips duplicates on re-import" do
      # Use "default" tag so import cart_id matches Memory.new's active cart
      cart = Personality::Cartridge.new(
        tag: "default", version: "1.0",
        memories: [Personality::TrainingMemory.new(subject: "dupe_subj", content: "d")],
        preferences: Personality::PreferencesConfig.from_hash({})
      )

      manager.import_memories(cart)
      result = manager.import_memories(cart)
      expect(result[:stored]).to eq(0)
      expect(result[:skipped]).to eq(1)
    end

    it "updates DB cart metadata" do
      cart = Personality::Cartridge.new(
        tag: "meta", version: "5.0",
        memories: [],
        preferences: Personality::PreferencesConfig.from_hash(
          {"identity" => {"name" => "Meta", "type" => "ai", "source" => "Titanfall", "tagline" => "Protocol 3"}}
        )
      )

      result = manager.import_memories(cart)
      db = Personality::DB.connection
      row = db.execute("SELECT version, source, name, type, tagline FROM carts WHERE id = ?", [result[:cart_id]]).first
      expect(row["version"]).to eq("5.0")
      expect(row["source"]).to eq("Titanfall")
    end
  end

  describe "#list_carts" do
    it "returns empty for nonexistent directory" do
      m = described_class.new(carts_dir: "/nonexistent/path")
      expect(m.list_carts).to eq([])
    end

    it "returns sorted paths" do
      create_pcart("beta")
      create_pcart("alpha")

      names = manager.list_carts.map { |p| File.basename(p) }
      expect(names).to eq(%w[alpha.pcart beta.pcart])
    end
  end

  describe "#cart_info" do
    it "returns tag, version, and memory_count" do
      path = create_pcart("info",
        memories: [{"subject" => "a", "content" => "b"}],
        version: "5.0")

      info = manager.cart_info(path)
      expect(info[:tag]).to eq("info")
      expect(info[:version]).to eq("5.0")
      expect(info[:memory_count]).to eq(1)
    end

    it "returns error hash for missing persona.yml in zip" do
      path = File.join(carts_dir, "nopersona.pcart")
      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("other.txt")
        zos.write("x")
      end

      info = manager.cart_info(path)
      expect(info).to have_key(:error)
    end

    it "returns error hash for invalid zip" do
      path = File.join(carts_dir, "corrupt.pcart")
      File.write(path, "not a zip")

      info = manager.cart_info(path)
      expect(info).to have_key(:error)
    end

    it "falls back to filename for missing tag" do
      path = File.join(carts_dir, "notag.pcart")
      Zip::OutputStream.open(path) do |zos|
        zos.put_next_entry("persona.yml")
        zos.write(YAML.dump({"memories" => [{"subject" => "x", "content" => "y"}]}))
      end

      info = manager.cart_info(path)
      expect(info[:tag]).to eq("notag")
    end
  end
end

RSpec.describe Personality::Cartridge do
  it "returns identity name when present" do
    cart = described_class.new(
      tag: "t",
      preferences: Personality::PreferencesConfig.from_hash({"identity" => {"name" => "Named"}})
    )
    expect(cart.name).to eq("Named")
  end

  it "returns tag when identity name is empty" do
    cart = described_class.new(tag: "fallback", preferences: Personality::PreferencesConfig.from_hash({}))
    expect(cart.name).to eq("fallback")
  end

  it "returns tag when identity name is nil" do
    cart = described_class.new(tag: "nilname", preferences: nil)
    expect(cart.name).to eq("nilname")
  end

  it "returns voice from TTS preferences" do
    cart = described_class.new(
      preferences: Personality::PreferencesConfig.from_hash({"tts" => {"voice" => "bt7274"}})
    )
    expect(cart.voice).to eq("bt7274")
  end

  it "returns nil voice when no preferences" do
    cart = described_class.new(preferences: nil)
    expect(cart.voice).to be_nil
  end

  it "returns 0 for nil memories" do
    expect(described_class.new(memories: nil).memory_count).to eq(0)
  end

  it "returns count for present memories" do
    cart = described_class.new(memories: [1, 2, 3])
    expect(cart.memory_count).to eq(3)
  end
end

RSpec.describe Personality::IdentityConfig do
  it "creates from hash" do
    cfg = described_class.from_hash({"name" => "Bot", "type" => "ai", "agent" => "core",
                                     "full_name" => "BT-7274", "version" => "1.0",
                                     "source" => "Titanfall", "tagline" => "Protocol 3"})
    expect(cfg.name).to eq("Bot")
    expect(cfg.type).to eq("ai")
    expect(cfg.source).to eq("Titanfall")
  end

  it "handles nil hash" do
    cfg = described_class.from_hash(nil)
    expect(cfg.name).to eq("")
    expect(cfg.type).to eq("")
  end

  it "omits empty values in to_hash" do
    cfg = described_class.from_hash({"name" => "Bot"})
    h = cfg.to_hash
    expect(h).to have_key("name")
    expect(h).not_to have_key("type")
  end

  it "omits nil values in to_hash" do
    cfg = described_class.new(name: "Bot", type: nil)
    h = cfg.to_hash
    expect(h).not_to have_key("type")
  end
end

RSpec.describe Personality::TTSConfig do
  it "creates from hash" do
    cfg = described_class.from_hash({"enabled" => false, "voice" => "bt7274"})
    expect(cfg.enabled).to be false
    expect(cfg.voice).to eq("bt7274")
  end

  it "defaults enabled to true and voice to empty" do
    cfg = described_class.from_hash({})
    expect(cfg.enabled).to be true
    expect(cfg.voice).to eq("")
  end

  it "handles nil hash" do
    cfg = described_class.from_hash(nil)
    expect(cfg.enabled).to be true
  end

  it "converts to hash" do
    cfg = described_class.from_hash({"enabled" => true, "voice" => "test"})
    expect(cfg.to_hash).to eq({"enabled" => true, "voice" => "test"})
  end
end

RSpec.describe Personality::PreferencesConfig do
  it "creates from hash with all sections" do
    cfg = described_class.from_hash({
      "identity" => {"name" => "Bot"},
      "tts" => {"voice" => "bt7274"},
      "custom" => "extra"
    })
    expect(cfg.identity.name).to eq("Bot")
    expect(cfg.tts.voice).to eq("bt7274")
    expect(cfg.extra).to eq({"custom" => "extra"})
  end

  it "handles nil hash" do
    cfg = described_class.from_hash(nil)
    expect(cfg.identity).to be_a(Personality::IdentityConfig)
    expect(cfg.tts).to be_a(Personality::TTSConfig)
  end

  it "includes identity in to_hash when non-empty" do
    cfg = described_class.from_hash({"identity" => {"name" => "Bot"}})
    expect(cfg.to_hash).to have_key("identity")
  end

  it "omits identity from to_hash when empty" do
    cfg = described_class.from_hash({})
    expect(cfg.to_hash).not_to have_key("identity")
  end

  it "includes tts when enabled" do
    cfg = described_class.from_hash({"tts" => {"enabled" => true, "voice" => ""}})
    expect(cfg.to_hash).to have_key("tts")
  end

  it "includes tts when voice is set" do
    cfg = described_class.from_hash({"tts" => {"enabled" => false, "voice" => "test"}})
    expect(cfg.to_hash).to have_key("tts")
  end

  it "omits tts when disabled and no voice" do
    cfg = described_class.from_hash({"tts" => {"enabled" => false, "voice" => ""}})
    expect(cfg.to_hash).not_to have_key("tts")
  end

  it "merges extra keys into to_hash" do
    cfg = described_class.from_hash({"custom" => "data", "other" => 42})
    h = cfg.to_hash
    expect(h["custom"]).to eq("data")
    expect(h["other"]).to eq(42)
  end

  it "handles nil extra" do
    cfg = described_class.new(
      identity: Personality::IdentityConfig.from_hash({}),
      tts: Personality::TTSConfig.from_hash({}),
      extra: nil
    )
    expect { cfg.to_hash }.not_to raise_error
  end
end
