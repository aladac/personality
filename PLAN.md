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

## Module Architecture

```
lib/personality/
  cli.rb                  # Thor CLI (existing)
  init.rb                 # psn init (existing)
  version.rb              # (existing)
  db.rb                   # Database connection + schema management
  embedding.rb            # Ollama HTTP client for embeddings
  chunker.rb              # Text chunking (2000 chars, 200 overlap)
  memory.rb               # Store/recall/search/forget memories (cart-scoped)
  indexer.rb              # Code + doc indexing with semantic search
  cart.rb                 # Persona/cart management
```

### `db.rb` — Database layer

- Singleton connection to `main.db`
- Loads sqlite-vec extension
- Runs schema migrations (versioned)
- Provides `Personality::DB.connection` accessor
- Transaction helpers

### `embedding.rb` — Ollama embeddings

- HTTP client using `net/http` (zero deps, Ollama is localhost)
- `Personality::Embedding.generate(text) -> Array[Float]`
- Configurable Ollama URL (default `http://localhost:11434`)
- Model: `nomic-embed-text` (768 dimensions)
- Truncates input to 8000 chars (token limit guard)

### `chunker.rb` — Text splitting

- `Personality::Chunker.split(text, size: 2000, overlap: 200) -> Array[String]`
- Overlapping window chunker matching psn's Python implementation
- Skips content < 10 chars

### `memory.rb` — Persistent memory

- Cart-scoped (memories belong to a persona)
- `store(subject:, content:, metadata: {})` — embed + insert into memories + vec_memories
- `recall(query:, limit: 5, subject: nil)` — embed query, vec search, join metadata
- `search(subject: nil, limit: 20)` — text search by subject (no embedding)
- `forget(id:)` — delete from both tables
- `list` — subjects with counts for active cart

### `indexer.rb` — Code/doc indexing

- `index_code(path:, project: nil, extensions: nil)` — walk dir, chunk, embed, store
- `index_docs(path:, project: nil)` — same for .md/.txt/.rst/.adoc
- `search(query:, type: :all, project: nil, limit: 10)` — semantic search across both
- `status(project: nil)` — counts by project
- `clear(project: nil, type: :all)` — delete index entries
- Default extensions: `.py .rs .rb .js .ts .go .java .c .cpp .h`
- Doc extensions: `.md .txt .rst .adoc`

### `cart.rb` — Persona management

- `Personality::Cart.find_or_create(tag)` — get/create cart by tag
- `Personality::Cart.active` — current cart (from `ENV["PERSONALITY_CART"]` or "default")
- Used by memory.rb to scope all operations

## CLI Commands

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

## Implementation Order

1. `db.rb` + update `init.rb` schema — foundation
2. `embedding.rb` — needed by everything else
3. `chunker.rb` — simple, no deps
4. `cart.rb` + CLI — persona management
5. `memory.rb` + CLI — store/recall/search
6. `indexer.rb` + CLI — code/doc indexing
7. Tests for each module

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
| Architecture | 3 MCP servers | 1 gem, CLI subcommands |
