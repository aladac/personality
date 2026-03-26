# TODO

## Phase 1: Foundation

- [x] `db.rb` — singleton connection, sqlite-vec loading, migration runner
- [x] Schema v2 — carts, memories, code_chunks, doc_chunks, vec0 virtual tables
- [x] Update `init.rb` to use `db.rb` for schema creation (remove inline SQL)
- [x] `embedding.rb` — Ollama HTTP client, `generate(text)`, 8000 char truncation
- [x] `chunker.rb` — overlapping window splitter (2000/200)
- [x] Tests for db, embedding, chunker

## Phase 2: Hooks & Context

- [x] `hooks.rb` service — JSONL logging, field truncation, config via `logging.toml`
- [x] `cli/hooks.rb` — all 9 hook event subcommands (pre-tool-use, post-tool-use, stop, subagent-stop, session-start, session-end, user-prompt-submit, pre-compact, notification)
- [x] `psn hooks install` — generate `hooks.json` for Claude Code settings
- [x] `context.rb` service — session file-read tracking (`/tmp/psn-context/`)
- [x] `cli/context.rb` — track-read, check, list, clear subcommands
- [x] Tests for hooks and context

## Phase 3: Cart & Memory

- [ ] `cart.rb` service — find_or_create, active, list, use, create
- [ ] `cli/cart.rb` — list, use, create subcommands
- [ ] `memory.rb` service — store, recall, search, forget, list (cart-scoped)
- [ ] `memory.rb` save hook — extract learnings from transcript, store with embeddings
- [ ] `memory.rb` precompact hook — deduplicate memories (>0.95 similarity)
- [ ] `cli/memory.rb` — store, recall, search, forget, list, save subcommands
- [ ] Tests for cart and memory

## Phase 4: TTS

- [ ] `tts.rb` service — piper synthesis, playback, PID tracking, voice resolution
- [ ] TTS interrupt protocol — natural stop flag, interrupt-check logic
- [ ] `cli/tts.rb` — speak, stop, mark-natural-stop, interrupt-check, voices, download, test, current, characters
- [ ] Voice download from HuggingFace (piper-voices repo)
- [ ] Tests for TTS service

## Phase 5: Indexer

- [ ] `indexer.rb` service — index_code, index_docs, search, status, clear
- [ ] `indexer.rb` hook — re-index on Write/Edit (PostToolUse)
- [ ] `cli/index.rb` — code, docs, search, status, clear, hook subcommands
- [ ] Tests for indexer

## Phase 6: MCP Server

- [ ] `mcp/server.rb` — JSON-RPC stdio transport, initialize, tools/list, tools/call
- [ ] `mcp/memory_handler.rb` — memory/* tool definitions + dispatch
- [ ] `mcp/index_handler.rb` — index/* tool definitions + dispatch
- [ ] `mcp/cart_handler.rb` — cart/* tool definitions + dispatch
- [ ] MCP resources — memory://subjects, memory://stats, memory://recent, memory://subject/{subject}
- [ ] `exe/psn-mcp` — standalone MCP binary
- [ ] `.mcp.json` template generation
- [ ] Tests for MCP handlers

## Phase 7: Integration & Polish

- [ ] `psn hooks session-start` — load persona instructions + intro prompt
- [ ] `psn hooks notification` — speak notifications via TTS
- [ ] End-to-end test: init → store memory → recall → verify
- [ ] End-to-end test: index code → search → verify results
- [ ] CLI help text and `--help` output review
- [ ] README update with usage examples
