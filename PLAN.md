# Plan: `psn init` Command

## Overview

Interactive CLI command that bootstraps the personality runtime environment.
Checks for required dependencies, prompts the user before installing anything,
and initialises the local database.

## Prerequisites

- Ruby >= 3.2
- `uv` (Python package manager) -- for piper-tts installation
- Internet access for model downloads

## Steps

### 1. Create sqlite-vec database

- Path: `~/.local/share/personality/main.db`
- Create parent directories if missing
- Initialise with sqlite-vec extension loaded
- Run schema migrations (embeddings table, metadata, etc.)
- Skip if database already exists and schema is current

### 2. Check for Ollama

- Detect via `which ollama` or `ollama --version`
- If present: report version and continue
- If missing: prompt user to install
  - macOS: `brew install ollama`
  - Linux: `curl -fsSL https://ollama.com/install.sh | sh`
- Start the service if not running (`ollama serve` or systemd)

### 3. Install nomic-embed-text model

- Check via `ollama list` for `nomic-embed-text`
- If Ollama was just installed in step 2: pull automatically without prompting
- If Ollama was already present: prompt before pulling
- Command: `ollama pull nomic-embed-text`

### 4. Install piper-tts

- Detect via `which piper` or `piper --help`
- If present: report version and continue
- If missing: prompt user to install via `uv` (see step 4a)
  - `uv tool install piper-tts --with pathvalidate`
    (`pathvalidate` is a missing transitive dep in piper-tts 1.4.1)

### 4a. Check for uv (prerequisite for piper-tts)

- Detect via `which uv` or `uv --version`
- If present: continue to piper install
- If missing: prompt user to install
  - If `brew` is available: `brew install uv`
  - Otherwise: `curl -LsSf https://astral.sh/uv/install.sh | sh`

## UX

- Each step prints status with TTY spinners/colours (pastel + tty-spinner)
- Prompt before any install action; `--yes` flag to skip confirmations
- Idempotent: safe to re-run, skips already-completed steps
- Summary at the end listing what was installed/skipped

## Command signature

```
psn init [--yes]
```

Registered as a Thor subcommand under the main `Personality::CLI`.

---

# Plan: Vector DB Architecture

## Overview

Port the Python psn vector DB capabilities (3 MCP servers) to the Ruby personality
gem using sqlite-vec instead of PostgreSQL/pgvector. Consolidate into a single SQLite
database with separate tables and vec0 virtual tables for each concern.

## Database: `~/.local/share/personality/main.db`

### Schema

sqlite-vec uses **vec0 virtual tables** for vector storage, linked to regular tables
via rowid. Each domain gets its own pair (data table + vec0 virtual table).

```sql
-- === Personas (carts) ===
CREATE TABLE IF NOT EXISTS carts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tag TEXT UNIQUE NOT NULL,
  version TEXT,
  name TEXT,
  type TEXT,
  tagline TEXT,
  source TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- === Memory ===
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cart_id INTEGER NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  content TEXT NOT NULL,
  metadata TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_memories_cart_id ON memories(cart_id);
CREATE INDEX IF NOT EXISTS idx_memories_subject ON memories(subject);

CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
  memory_id INTEGER PRIMARY KEY,
  embedding float[768]
);

-- === Code Index ===
CREATE TABLE IF NOT EXISTS code_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  content TEXT NOT NULL,
  language TEXT,
  project TEXT,
  chunk_index INTEGER DEFAULT 0,
  indexed_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_code_chunks_project ON code_chunks(project);

CREATE VIRTUAL TABLE IF NOT EXISTS vec_code USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding float[768]
);

-- === Doc Index ===
CREATE TABLE IF NOT EXISTS doc_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  content TEXT NOT NULL,
  project TEXT,
  chunk_index INTEGER DEFAULT 0,
  indexed_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_doc_chunks_project ON doc_chunks(project);

CREATE VIRTUAL TABLE IF NOT EXISTS vec_docs USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding float[768]
);

-- === Schema version ===
CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY,
  applied_at TEXT DEFAULT (datetime('now'))
);
```

### Vector search pattern (sqlite-vec)

```sql
-- Find similar memories (cosine distance via vec0)
SELECT m.id, m.subject, m.content, v.distance
FROM vec_memories v
INNER JOIN memories m ON m.id = v.memory_id
WHERE v.embedding MATCH ?    -- ? = query embedding as JSON array
  AND k = ?                  -- ? = limit
ORDER BY v.distance;
```

## Design Principle: Service Objects + Thin Interfaces

Business logic lives in **service objects** (plain Ruby classes). Both CLI commands
and MCP tool handlers are thin wrappers that delegate to the same services.
No logic in the interface layer — ever.

```
                   ┌─────────────┐
                   │  Service    │
                   │  Objects    │
                   │             │
                   │ DB          │
                   │ Embedding   │
                   │ Chunker     │
                   │ Memory      │
                   │ Indexer     │
                   │ Cart        │
                   └──────┬──────┘
                          │
              ┌───────────┼───────────┐
              │                       │
      ┌───────▼───────┐      ┌───────▼───────┐
      │  CLI Layer    │      │  MCP Layer    │
      │  (Thor)       │      │  (JSON-RPC)   │
      │               │      │               │
      │ psn memory *  │      │ memory/*      │
      │ psn index *   │      │ index/*       │
      │ psn cart *    │      │ cart/*        │
      └───────────────┘      └───────────────┘
```

## Module Architecture

```
lib/personality/
  # Core
  version.rb                # (existing)
  db.rb                     # Database connection + schema + migrations
  embedding.rb              # Ollama HTTP client for embeddings
  chunker.rb                # Text chunking (2000 chars, 200 overlap)

  # Service objects (all logic lives here)
  memory.rb                 # Store/recall/search/forget (cart-scoped)
  indexer.rb                # Code + doc indexing with semantic search
  cart.rb                   # Persona/cart management

  # CLI layer (thin Thor wrappers)
  cli.rb                    # Root CLI + init (existing)
  cli/
    memory.rb               # psn memory subcommands
    index.rb                # psn index subcommands
    cart.rb                 # psn cart subcommands

  # MCP layer (thin JSON-RPC handlers)
  mcp/
    server.rb               # MCP server bootstrap + stdio transport
    memory_handler.rb       # memory/* tool definitions + dispatch
    index_handler.rb        # index/* tool definitions + dispatch
    cart_handler.rb         # cart/* tool definitions + dispatch

  # Init (existing)
  init.rb
```

### Core: `db.rb` — Database layer

- Singleton connection to `main.db`
- Loads sqlite-vec extension
- Runs schema migrations (versioned)
- `Personality::DB.connection` accessor
- Transaction helpers

### Core: `embedding.rb` — Ollama embeddings

- HTTP client using `net/http` (zero deps, Ollama is localhost)
- `Personality::Embedding.generate(text) -> Array[Float]`
- Configurable Ollama URL (default `http://localhost:11434`)
- Model: `nomic-embed-text` (768 dimensions)
- Truncates input to 8000 chars (token limit guard)

### Core: `chunker.rb` — Text splitting

- `Personality::Chunker.split(text, size: 2000, overlap: 200) -> Array[String]`
- Overlapping window chunker matching psn's Python implementation
- Skips content < 10 chars

### Service: `memory.rb` — Persistent memory

- Cart-scoped (memories belong to a persona)
- Returns plain hashes — no formatting, no output
- `store(subject:, content:, metadata: {})` → `{id:, subject:}`
- `recall(query:, limit: 5, subject: nil)` → `{memories: [...]}`
- `search(subject: nil, limit: 20)` → `{memories: [...]}`
- `forget(id:)` → `{deleted: true/false}`
- `list` → `{subjects: [{subject:, count:}, ...]}`

### Service: `indexer.rb` — Code/doc indexing

- Returns plain hashes
- `index_code(path:, project: nil, extensions: nil)` → `{indexed:, project:, errors:}`
- `index_docs(path:, project: nil)` → `{indexed:, project:, errors:}`
- `search(query:, type: :all, project: nil, limit: 10)` → `{results: [...]}`
- `status(project: nil)` → `{code_index: [...], doc_index: [...]}`
- `clear(project: nil, type: :all)` → `{cleared:, project:}`
- Default code extensions: `.py .rs .rb .js .ts .go .java .c .cpp .h`
- Doc extensions: `.md .txt .rst .adoc`

### Service: `cart.rb` — Persona management

- `Personality::Cart.find_or_create(tag)` → `{id:, tag:}`
- `Personality::Cart.active` → current cart from `ENV["PERSONALITY_CART"]` or "default"
- `Personality::Cart.list` → `[{id:, tag:, name:, ...}, ...]`
- `Personality::Cart.use(tag)` → sets active cart
- `Personality::Cart.create(tag, name: nil, type: nil)` → `{id:, tag:}`

## CLI Layer

Thin Thor subcommands. Each method: parse args → call service → format output.

```
psn init                           # (existing) bootstrap environment
psn memory store SUBJECT CONTENT   # store a memory
psn memory recall QUERY            # semantic recall
psn memory search [--subject X]    # text search
psn memory forget ID               # delete memory
psn memory list                    # list subjects
psn index code PATH [--project X]  # index code files
psn index docs PATH [--project X]  # index doc files
psn index search QUERY [--type X]  # semantic search
psn index status [--project X]     # show stats
psn index clear [--project X]      # clear index
psn cart list                      # list personas
psn cart use TAG                   # switch active cart
psn cart create TAG [--name X]     # create new persona
```

CLI formatting uses pastel + tty-table + tty-spinner for human-readable output.

## MCP Layer

JSON-RPC stdio server. Each handler: parse tool input → call service → return JSON.

### Transport

- `exe/psn-mcp` — standalone MCP server binary (stdio transport)
- Also launchable via `psn mcp` CLI subcommand
- JSON-RPC 2.0 over stdin/stdout
- Implements MCP protocol: `initialize`, `tools/list`, `tools/call`

### Tool Definitions

MCP tools mirror CLI commands 1:1. Tool names use `/` namespacing.

```json
// memory_handler.rb tools
{"name": "memory/store",  "inputSchema": {"subject": "string", "content": "string", "metadata": "object?"}}
{"name": "memory/recall", "inputSchema": {"query": "string", "limit": "integer?", "subject": "string?"}}
{"name": "memory/search", "inputSchema": {"subject": "string?", "limit": "integer?"}}
{"name": "memory/forget", "inputSchema": {"id": "integer"}}
{"name": "memory/list",   "inputSchema": {}}

// index_handler.rb tools
{"name": "index/code",    "inputSchema": {"path": "string", "project": "string?", "extensions": "string[]?"}}
{"name": "index/docs",    "inputSchema": {"path": "string", "project": "string?"}}
{"name": "index/search",  "inputSchema": {"query": "string", "type": "string?", "project": "string?", "limit": "integer?"}}
{"name": "index/status",  "inputSchema": {"project": "string?"}}
{"name": "index/clear",   "inputSchema": {"project": "string?", "type": "string?"}}

// cart_handler.rb tools
{"name": "cart/list",     "inputSchema": {}}
{"name": "cart/use",      "inputSchema": {"tag": "string"}}
{"name": "cart/create",   "inputSchema": {"tag": "string", "name": "string?", "type": "string?"}}
```

### MCP Resources (read-only data exposed to clients)

```
memory://subjects   — all memory subjects with counts
memory://stats      — total memories, subjects, date range
memory://recent     — last 10 memories
memory://subject/{subject} — all memories for a subject
```

### Handler Pattern

Each handler follows the same pattern:

```ruby
# lib/personality/mcp/memory_handler.rb
module Personality
  module MCP
    class MemoryHandler
      def tools
        # Return array of tool definition hashes
      end

      def call(name, arguments)
        case name
        when "memory/store"
          Memory.new.store(**arguments.slice(:subject, :content, :metadata))
        when "memory/recall"
          Memory.new.recall(**arguments.slice(:query, :limit, :subject))
        # ...
        end
      end
    end
  end
end
```

### Configuration for Claude Code

The MCP server is registered in `.mcp.json` or `settings.json`:

```json
{
  "mcpServers": {
    "personality": {
      "command": "psn-mcp",
      "args": [],
      "env": {
        "PERSONALITY_CART": "bt7274"
      }
    }
  }
}
```

## Executables

```
exe/
  psn       # (existing) CLI entry point
  psn-mcp   # MCP server entry point (stdio)
```

`psn-mcp` is a thin script:

```ruby
#!/usr/bin/env ruby
require "personality"
Personality::MCP::Server.run
```

## Claude Code Hooks

Hooks are CLI commands that Claude Code invokes at lifecycle events. Each reads
JSON from stdin, performs side effects, and optionally prints JSON to stdout.

### Hook Configuration (`hooks.json`)

Generated by `psn init` or `psn hooks install`. Registers `psn hooks <event>`
as the command for each Claude Code hook event.

```json
{
  "hooks": {
    "PreToolUse":        [{"hooks": [{"type": "command", "command": "psn hooks pre-tool-use",        "timeout": 5000}]}],
    "PostToolUse":       [
      {"matcher": "Read",       "hooks": [{"type": "command", "command": "psn context track-read",   "timeout": 5000}]},
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "psn index hook",           "timeout": 30000}]}
    ],
    "Stop":              [{"hooks": [
      {"type": "command", "command": "psn tts mark-natural-stop", "timeout": 1000},
      {"type": "command", "command": "psn memory save",           "timeout": 5000}
    ]}],
    "SubagentStop":      [{"hooks": [{"type": "command", "command": "psn hooks subagent-stop",       "timeout": 5000}]}],
    "SessionStart":      [{"hooks": [{"type": "command", "command": "psn hooks session-start",       "timeout": 5000}]}],
    "SessionEnd":        [{"hooks": [
      {"type": "command", "command": "psn hooks session-end", "timeout": 5000},
      {"type": "command", "command": "psn tts stop",          "timeout": 1000}
    ]}],
    "UserPromptSubmit":  [{"hooks": [
      {"type": "command", "command": "psn hooks user-prompt-submit", "timeout": 5000},
      {"type": "command", "command": "psn tts interrupt-check",      "timeout": 1000}
    ]}],
    "PreCompact":        [{"hooks": [{"type": "command", "command": "psn memory save",               "timeout": 5000}]}],
    "Notification":      [{"hooks": [{"type": "command", "command": "psn hooks notification",        "timeout": 5000}]}]
  }
}
```

### Hook Service: `hooks.rb`

Service object for hook logic. All hooks log to `~/.config/psn/hooks.jsonl`.

- `log(event, data)` — append JSONL entry with timestamp, session ID, truncated fields
- Configurable field truncation via `~/.config/psn/logging.toml`
- Preserves path fields (file_path, cwd, etc.) from truncation

### Hook CLI: `cli/hooks.rb`

```
psn hooks pre-tool-use         # Log + allow (gate hook, can block)
psn hooks post-tool-use        # Log only
psn hooks stop                 # Log only
psn hooks subagent-stop        # Log only
psn hooks session-start        # Log + output persona instructions + intro prompt
psn hooks session-end          # Log only
psn hooks user-prompt-submit   # Log + allow (gate hook, can block/modify)
psn hooks pre-compact          # Log only
psn hooks notification         # Log + speak via TTS
psn hooks install              # Generate hooks.json in project/global settings
```

### Context Tracking: `context.rb` + `cli/context.rb`

Tracks which files Claude has read during a session (for require-read validation).

- Session-scoped file tracking in `/tmp/psn-context/{session_id}.json`
- Uses `CLAUDE_SESSION_ID` env var for session isolation

```
psn context track-read         # PostToolUse hook: record file read (stdin JSON)
psn context check FILE         # Check if file is in session context
psn context list               # List all files in current session context
psn context clear              # Clear session context
```

### TTS Hooks: `tts.rb` + `cli/tts.rb`

Text-to-speech with piper, integrated into Claude Code lifecycle.

**Hook commands (called by hooks.json):**
```
psn tts mark-natural-stop      # Stop hook: set flag (agent completed naturally)
psn tts interrupt-check        # UserPromptSubmit: kill TTS if user interrupted
psn tts stop                   # SessionEnd: kill any playing TTS
```

**User-facing commands:**
```
psn tts speak TEXT [--voice V]  # Speak text with active persona's voice
psn tts voices                  # List installed voice models
psn tts download VOICE          # Download piper voice from HuggingFace
psn tts test [--voice V]        # Test voice with sample text
psn tts current                 # Show active persona's voice config
psn tts characters              # List character voice models
```

**TTS interrupt protocol:**
- Stop hook sets `data/tts_natural_stop` flag file
- UserPromptSubmit checks flag: present = natural stop (TTS continues),
  absent = user interrupted (TTS killed)
- Works because Stop hooks only fire on natural completion, not user ESC/Ctrl+C

**Voice resolution:**
1. Check `voices/` directory (character voices: BT7274, etc.)
2. Check `~/.local/share/psn/voices/` (downloaded piper voices)
3. Fall back to active cart's configured voice or `en_US-lessac-medium`

### Memory Save Hook: `memory.rb`

Called on Stop and PreCompact events.

```
psn memory save                # Extract learnings from transcript, store to DB
psn memory hook-precompact     # Deduplicate near-identical memories (similarity > 0.95)
```

- Reads `transcript_path` from stdin JSON
- Extracts learnings from conversation transcript
- Stores each learning with subject, content, metadata, embedding
- PreCompact dedup finds pairs with >0.95 similarity and merges

### Index Hook: `indexer.rb`

Called on PostToolUse for Write|Edit events.

```
psn index hook                 # Re-index the written/edited file immediately
```

- Reads `tool_input.file_path` and `cwd` from stdin JSON
- Skips non-code/non-doc extensions
- Generates embedding and upserts into code_chunks/doc_chunks + vec tables
- Project name derived from cwd directory name

### Module Architecture (updated)

```
lib/personality/
  # Core
  version.rb                # (existing)
  db.rb                     # Database connection + schema + migrations
  embedding.rb              # Ollama HTTP client for embeddings
  chunker.rb                # Text chunking (2000 chars, 200 overlap)

  # Service objects (all logic lives here)
  memory.rb                 # Store/recall/search/forget/save (cart-scoped)
  indexer.rb                # Code + doc indexing with semantic search
  cart.rb                   # Persona/cart management
  hooks.rb                  # Hook logging + event processing
  context.rb                # Session file-read tracking
  tts.rb                    # TTS synthesis + playback + interrupt protocol

  # CLI layer (thin Thor wrappers)
  cli.rb                    # Root CLI + init (existing)
  cli/
    memory.rb               # psn memory subcommands
    index.rb                # psn index subcommands
    cart.rb                 # psn cart subcommands
    hooks.rb                # psn hooks subcommands
    context.rb              # psn context subcommands
    tts.rb                  # psn tts subcommands

  # MCP layer (thin JSON-RPC handlers)
  mcp/
    server.rb               # MCP server bootstrap + stdio transport
    memory_handler.rb       # memory/* tool definitions + dispatch
    index_handler.rb        # index/* tool definitions + dispatch
    cart_handler.rb         # cart/* tool definitions + dispatch

  # Init (existing)
  init.rb
```

## Implementation Order

1. `db.rb` + update `init.rb` schema — foundation
2. `embedding.rb` — needed by everything else
3. `chunker.rb` — simple, no deps
4. `hooks.rb` service + `cli/hooks.rb` — logging backbone for all hooks
5. `context.rb` service + `cli/context.rb` — file-read tracking
6. `cart.rb` service + `cli/cart.rb` + `mcp/cart_handler.rb`
7. `memory.rb` service + `cli/memory.rb` + `mcp/memory_handler.rb` (incl. save hook)
8. `tts.rb` service + `cli/tts.rb` — TTS + interrupt protocol
9. `indexer.rb` service + `cli/index.rb` + `mcp/index_handler.rb` (incl. index hook)
10. `mcp/server.rb` — MCP transport + tool routing
11. `exe/psn-mcp` — MCP binary
12. `psn hooks install` — generate hooks.json
13. Tests for each layer (service, CLI, MCP, hooks)

## Key Differences from psn (Python)

| Aspect | psn (Python/PostgreSQL) | personality (Ruby/SQLite) |
|--------|------------------------|--------------------------|
| Vector storage | pgvector column type | vec0 virtual table (separate) |
| Vector search | `<=>` cosine operator | `MATCH` + `k` parameter |
| Similarity score | `1 - (a <=> b)` | `distance` (lower = closer) |
| IDs | UUID strings | INTEGER autoincrement |
| Metadata | JSONB column | TEXT (JSON string) |
| Connection | psycopg + config | sqlite3 gem, single file |
| Embedding | urllib (raw HTTP) | net/http (raw HTTP) |
| Architecture | 3 separate MCP servers | 1 gem: shared services, CLI + single MCP server |
| Interface | MCP only | CLI + MCP + hooks (same service objects) |
| Hooks | Python scripts + Typer CLI | Ruby service objects + Thor CLI |
| TTS | piper via Python import | piper via CLI subprocess |
| Context tracking | /tmp file per session | /tmp file per session (same pattern) |
