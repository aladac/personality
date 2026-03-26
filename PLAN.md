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
