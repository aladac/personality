# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

`personality` is a Ruby gem providing infrastructure for Claude Code: persistent memory with vector search, code/doc indexing, TTS, persona management, and MCP server.

- **CLI**: `psn` (Thor-based, subcommands: init, memory, index, cart, tts, hooks, context)
- **MCP Server**: `psn-mcp` (stdio transport, 13 tools, 3 resources)
- **Database**: SQLite + sqlite-vec at `~/.local/share/personality/main.db`
- **Embeddings**: Ollama + nomic-embed-text (768 dimensions)
- **TTS**: piper-tts via subprocess

## Architecture

Service objects hold all logic. CLI and MCP are thin wrappers.

```
lib/personality/
  db.rb          # SQLite connection, sqlite-vec, migrations
  embedding.rb   # Ollama HTTP client
  chunker.rb     # Text splitting (2000/200 overlap)
  cart.rb        # Persona management
  memory.rb      # Vector memory (cart-scoped)
  indexer.rb     # Code/doc indexing + semantic search
  hooks.rb       # Claude Code hook logging
  context.rb     # Session file-read tracking
  tts.rb         # Piper TTS synthesis + playback
  cli.rb         # Root Thor CLI
  cli/           # Thor subcommands (thin wrappers)
  mcp/server.rb  # MCP server (uses official mcp gem)
```

## Key Dependencies

| Gem | Purpose |
|-----|---------|
| `mcp` ~> 0.9.1 | Official MCP Ruby SDK (modelcontextprotocol/ruby-sdk) |
| `sqlite3` + `sqlite-vec` | Database + vector search |
| `thor` | CLI framework |
| `pastel` + `tty-table` + `tty-spinner` | Terminal output |
| `toml-rb` | Config parsing |
| `llm.rb` | LLM client (future use) |

## MCP Server Notes

- **Tool names use dots** not slashes: `memory.store`, `index.search` (MCP spec forbids `/`)
- **Tool blocks use keyword args**: `do |subject:, content:, server_context:, **opts|`
- **Must return `MCP::Tool::Response`**: `MCP::Tool::Response.new([{type: "text", text: json}])`
- **Protocol requires initialize handshake** before tools/call works
- See `docs/mcp-ruby-sdk.md` for full API reference

## Commands

```bash
bundle exec rspec --format documentation  # Run tests
bundle exec ruby exe/psn help             # CLI help
bundle exec ruby exe/psn memory store SUBJECT CONTENT
bundle exec ruby exe/psn tts speak "text" --voice bt7274
bundle exec ruby exe/psn-mcp              # Start MCP server (stdio)
```

## Testing

Tests use RSpec. External dependencies are stubbed:
- `Personality::Embedding.generate` — stubbed with fake 768-dim vectors
- `Personality::DB` — uses temp databases per test, cleaned up in `after` blocks
- No Ollama or piper required for tests

Run: `bundle exec rspec --format documentation`

## Database

Schema v2 with versioned migrations in `db.rb`:
- `carts` — persona registry
- `memories` + `vec_memories` — cart-scoped memory with vector embeddings
- `code_chunks` + `vec_code` — code index
- `doc_chunks` + `vec_docs` — doc index
- `schema_version` — migration tracking

sqlite-vec uses `vec0` virtual tables. Vector search pattern:
```sql
SELECT m.*, v.distance FROM vec_memories v
INNER JOIN memories m ON m.id = v.memory_id
WHERE v.embedding MATCH ? AND k = ?
ORDER BY v.distance
```
