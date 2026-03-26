# Personality

Infrastructure layer for [Claude Code](https://docs.anthropic.com/en/docs/claude-code): persistent memory with vector search, code/doc indexing, TTS, persona management, and MCP server.

[![Gem Version](https://badge.fury.io/rb/personality.svg)](https://rubygems.org/gems/personality)
[![CI](https://github.com/aladac/personality/actions/workflows/main.yml/badge.svg)](https://github.com/aladac/personality/actions/workflows/main.yml)

## Features

- **Memory** — Cart-scoped persistent memory with vector similarity search
- **Code/Doc Indexing** — Semantic search across codebases and documentation
- **TTS** — Text-to-speech via piper-tts with voice management
- **Personas** — Cartridge-based persona system with identity, preferences, and memories
- **MCP Server** — 18 tools and 3 resources over stdio transport

## Installation

```bash
gem install personality
```

Or add to your Gemfile:

```ruby
gem "personality"
```

### Dependencies

| Dependency | Purpose |
|------------|---------|
| [Ollama](https://ollama.com) | Embeddings (nomic-embed-text) |
| [piper-tts](https://github.com/rhasspy/piper) | Text-to-speech synthesis |
| SQLite | Database (bundled via sqlite3 gem) |

## Usage

### CLI

```bash
psn help                          # Show all commands
psn memory store SUBJECT CONTENT  # Store a memory
psn memory recall QUERY           # Recall by similarity
psn index code ./src              # Index code for search
psn index search "auth handler"   # Semantic code search
psn tts speak "Hello world"       # Speak text aloud
psn cart list                     # List personas
```

### MCP Server

Start the MCP server for Claude Code integration:

```bash
psn-mcp
```

Tools use dot notation: `memory.store`, `memory.recall`, `index.search`, `cart.use`, etc.

### As a Claude Code Plugin

Add to your Claude Code `settings.json`:

```json
{
  "plugins": ["personality"]
}
```

## Architecture

Service objects hold all logic. CLI and MCP are thin wrappers.

```
lib/personality/
  db.rb          # SQLite + sqlite-vec, migrations
  embedding.rb   # Ollama HTTP client (nomic-embed-text, 768 dims)
  chunker.rb     # Text splitting (2000 chars, 200 overlap)
  memory.rb      # Vector memory (cart-scoped)
  indexer.rb     # Code/doc indexing + semantic search
  cart.rb        # Persona management
  tts.rb         # Piper TTS synthesis + playback
  mcp/server.rb  # MCP server (official mcp gem)
```

## Development

```bash
bundle install
bundle exec rake          # Run tests + linter
bundle exec rspec         # Tests only
bundle exec standardrb    # Linter only
```

Tests stub external dependencies (Ollama, piper) — no services needed to run the suite.

## Releasing

Push a stable version tag to trigger the release workflow:

```bash
# Update lib/personality/version.rb, then:
git commit -am "Bump version to X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

This publishes to [RubyGems](https://rubygems.org/gems/personality), [GitHub Packages](https://github.com/aladac/personality/packages), and creates a [GitHub Release](https://github.com/aladac/personality/releases) with the `.gem` attached.

Pre-release versions (e.g. `v0.2.0.pre1`) are not published.

## License

[MIT](LICENSE.txt)
