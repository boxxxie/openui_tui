# OpenUI TUI Maker & Studio (`openui_tui`)

**Conversational Terminal UI (TUI) Studio, Agentic UI Builder, and 1Hz Live Telemetry Engine for Elixir — powered by [`openui_lang`](../openui_lang), [Jido](https://hex.pm/packages/jido), Google Gemini, and TypeSafe Jev.**

`openui_tui` lets you build, inspect, and evolve interactive Terminal UIs through an **`antigravity-cli`-inspired chat interface** (`mix openui.studio`). Each app in the workspace has its own isolated chat history, revision stack (`/undo`), interactive keyboard controls, and zero-token 1Hz live data streams (`Memcached`, `BEAM VM`, Linux CLI, and `openui_tui`'s own LiteLLM/Jev telemetry).

---

## Highlights

- **`antigravity-cli` Style Studio Chat (`mix openui.studio`):**
  - Clean bottom composer dock (`❯ `) with live `/` slash-command autocomplete popup (`/model`, `/new`, `/apps`, `/split`, `/code`, `/undo`, `/reset`, `/help`).
  - Inline Jido agent tool execution trees (`├─ ✔ Jido.ClassifyIntent`, `├─ ✔ Jido.EvolveUI`, `├─ ✔ Jido.CreateApp`, `├─ ✔ Jido.SwitchModel`, `├─ ✔ Jido.AnswerQuestion`).
  - Per-turn and cumulative session receipts showing active model badge (`gemini-3.8-flash`, `gemini-4-argon (low)`), prompt/completion token counts, cache hit tier (`L1 Cachex` / `L2 Memcached`), and `$` spend.
- **Jido Agent & Action Architecture (`OpenUITUI.Studio.Agent`):**
  - Built on `{:jido, "~> 2.4"}` (`OpenUITUI.Jido`) with 5 typed `Jido.Action` workflows:
    1. `OpenUITUI.Studio.Actions.ClassifyIntent` — Calls TypeSafe Jev (`typesafe/jev-latest` on `/v1/systemone`) in ~190ms at `$0.00` effective cost to route between `create_new_app`, `switch_model`, `ask_question_or_meta`, and `build_or_modify_ui`.
    2. `OpenUITUI.Studio.Actions.CreateApp` — Creates a brand-new App with its own isolated chat conversation (`"make new app"`, `"make a new app for llm metrics for the openui_tui app itself"`) and adds it to the App list without overwriting your current app.
    3. `OpenUITUI.Studio.Actions.SwitchModel` — Switches the active Gemini model and reasoning effort via natural language (`"use argon low"`, `"use gemini 3.8 flash"`) or `/model <name> [low|medium|high]`.
    4. `OpenUITUI.Studio.Actions.AnswerQuestion` — Answers architectural or live-metrics questions in chat without mutating the active UI.
    5. `OpenUITUI.Studio.Actions.EvolveUI` — Evolves or patches the active App's `openui-lang` program (`v1 ➔ v2`) and records a structured `Δ UI Changes` diff (`+added`, `~updated`, `-pruned`).
- **Two-Loop Real-Time Data Plane (Zero LLM Tokens at 1Hz):**
  - **Loop 1 (Control Plane):** Jev + Gemini generate or patch declarative `openui-lang` statements (`StreamSource(...)`, `Bind(...)`, `Dashboard(...)`, `Panel(...)`, `Form(...)`) only when you ask in Chat.
  - **Loop 2 (1Hz Elixir Data Plane):** `OpenUITUI.LiveSession` polls local sources every 1000ms in pure Elixir with **zero LLM token spend**:
    - `StreamSource("memcached", "127.0.0.1:11211", 1000)` — Powered by the standalone [`OpenUITUI.Memcached.Parser`](lib/openui_tui/memcached/parser.ex) library (`stats`, `stats slabs`, `stats items`, rate deltas, 18-point ring-buffer sparklines, and top populated slab distribution).
    - `StreamSource("openui_telemetry", "local", 1000)` — Powered by [`OpenUITUI.LLMTelemetry.Parser`](lib/openui_tui/llm_telemetry/parser.ex), streaming real-time Gemini & TypeSafe Jev calls, L1/L2 cache hit rates, token counts, and `SpendGuard` budget metrics from `priv/telemetry/events.jsonl`.
    - `StreamSource("beam", "beam", "erlang:memory", "term", 1000)` — Live BEAM VM memory and process count bindings.
    - `StreamSource("host", "exec", "vmstat 1 2", "columns", 2000)` — Allowlisted local CLI metric probes normalized via `OpenUITUI.SourceNormalizer`.
- **5 Elixir TUI Renderers:**
  - `:fixed_80` (responsive full-screen / 80-column Unicode box-drawing renderer with `╭─ ◆ Title ───╮` bordered panels, braille/block sparklines, and 1/8th fractional bar lists)
  - `:owl` (`Owl` bordered boxes and ANSI tag styling)
  - `:table_rex` (`TableRex` data-dense ASCII/Unicode tables)
  - `:pure_ansi` (zero-dependency streaming ANSI renderer)
  - `:compact_ops` (single-screen SRE summary renderer)
- **Two-Tier Caching & `$1.00` Spend Guardrail:**
  - Every Jev and Gemini request is deduplicated through **L1 `Cachex`** (in-memory ETS) and **L2 `Memcached`** (`127.0.0.1:11211`).
  - `OpenUITUI.SpendGuard` enforces a configurable `$1.00` budget cap (`OPENUI_BUDGET_LIMIT_USD`) and automatically generates Markdown + OpenUI spend reports on budget threshold events.

---

## Prerequisites & Installation

1. **Elixir `~> 1.18`** (OTP 27+)
2. **[`openui_lang`](../openui_lang)** cloned alongside `openui_tui` (or configured in `mix.exs`)
3. **Optional Local Services:**
   - **LiteLLM Proxy** (or OpenAI-compatible gateway) for live Gemini + TypeSafe Jev calls
   - **Memcached** (`127.0.0.1:11211`) for L2 response caching and the live Memcached telemetry starter app (falls back gracefully to deterministic local metrics if Memcached is not running)

```bash
git clone https://github.com/boxxxie/openui_lang.git
git clone https://github.com/boxxxie/openui_tui.git
cd openui_tui
mix deps.get
```

---

## Configuration

`openui_tui` ships with safe public defaults in [`config/config.exs`](config/config.exs) (`http://localhost:4000` and no hardcoded keys).

You can configure your LiteLLM Proxy endpoint and virtual API key using **either** environment variables (see [`.env.example`](.env.example)) **or** a gitignored `config/local.secret.exs` file (see [`config/local.secret.exs.example`](config/local.secret.exs.example)):

### Option A: `config/local.secret.exs` (Recommended for Local Dev)

```bash
cp config/local.secret.exs.example config/local.secret.exs
```

Edit `config/local.secret.exs` (this file is automatically gitignored):

```elixir
import Config

config :openui_tui,
  litellm_url: "http://localhost:4000",
  api_key: "sk-your-litellm-virtual-key",
  default_model: "gemini-3.8-flash",
  jev_model: "typesafe/jev-latest",
  budget_limit_usd: 1.00
```

### Option B: Environment Variables

```bash
export OPENUI_LITELLM_URL="http://localhost:4000"
export OPENUI_LITELLM_API_KEY="sk-your-litellm-virtual-key"
export OPENUI_DEFAULT_MODEL="gemini-3.8-flash"
export OPENUI_JEV_MODEL="typesafe/jev-latest"
export OPENUI_BUDGET_LIMIT_USD="1.00"
```

### Supported Gemini Models

Defaults to `gemini-3.8-flash`. Switch models anytime in Chat (`"use argon low"`, `"use gemini 3.1 pro"`) or via `/model`:
- `gemini-3.8-flash` *(default)*
- `gemini-4-argon` *(supports `low`, `medium`, `high` reasoning effort)*
- `gemini-3.7-flash`
- `gemini-3.6-flash`
- `gemini-3.5-flash` / `gemini-3.5-flash-lite`
- `gemini-3.1-pro` / `gemini-3.1-flash-lite`
- `gemini-2.5-pro` / `gemini-2.5-flash` / `gemini-2.5-flash-lite`

---

## Usage

### 1. Launch Interactive OpenUI Studio (`mix openui.studio`)

```bash
mix openui.studio
```

#### Keyboard Shortcuts & Slash Commands in Studio

| Key / Command | Action |
| :--- | :--- |
| **`Tab`** | Toggle between **F1:Chat** and **F2:Live App** (full-screen live 1Hz dashboard) |
| **`F1` / `F2` / `F3` / `F4`** | Switch directly to **Chat**, **Live App**, **Split View** (Chat + Live UI side-by-side), or **Code & State Inspector** |
| **`↑` / `↓` / `←` / `→` / `Enter`** | Navigate and activate interactive `Form` controls (`Select`, `Toggle`, `Field`, `Button`) in **Live App** or **Split View** |
| **`/`** | Open the live slash-command autocomplete menu above the composer dock |
| **`/model <name> [effort]`** | Switch active Gemini model & effort (e.g. `/model gemini-4-argon low`, `/model gemini-3.8-flash`) |
| **`/new <Title>`** | Create a new App with its own isolated chat (or just type `"make new app"` in chat!) |
| **`/apps`** | Open the App Switcher modal (`1`–`9` to switch apps) |
| **`/undo`** | Revert the active App to its previous `openui-lang` revision |
| **`/reset`** | Reset starter seed apps cleanly to `v1` |
| **`/quit`** (or `Ctrl+C`) | Exit OpenUI Studio |

### 2. Non-Interactive CLI & Agent Harness (`mix openui.cli`)

Inspect frames, simulate keystrokes, or test conversational prompts from the terminal without entering raw TTY mode:

```bash
# Render the Live App view of app #1 (Memcached & BEAM Live Telemetry)
mix openui.cli --view app --app 1

# Render Split View (Chat + Live App) at 128x36 terminal dimensions
mix openui.cli --view split --width 128 --height 36

# Send a chat prompt in an isolated sandbox and inspect the Jido trace + rendered frame
mix openui.cli --sandbox --trace --say "use argon low"
mix openui.cli --sandbox --trace --say "make a new app for llm metrics for the openui_tui app itself"

# Run the automated Studio smoke suite
mix openui.cli --smoke
```

### 3. Run the 5-Renderer & Caching Benchmark (`mix openui.demo`)

```bash
mix openui.demo
```

---

## Standalone Parsers & Data Plane Libraries

### 1. `OpenUITUI.Memcached.Parser` ([`lib/openui_tui/memcached/parser.ex`](lib/openui_tui/memcached/parser.ex))

A pure, standalone Elixir parser for raw Memcached ASCII protocol output (`stats`, `stats slabs`, `stats items`) that computes structured metrics, per-slab utilization, rate deltas, and `$live_*` OpenUI bindings:

```elixir
alias OpenUITUI.Memcached.Parser

snapshot = Parser.parse_raw_sections(raw_stats, raw_slabs, raw_items)
# => %{
#   service: %{pid: 1426, version: "1.6.45", uptime_seconds: 1330790, ...},
#   cache: %{get_hits: 595167, get_misses: 119859, hit_rate_pct: 83.24, ...},
#   memory: %{bytes_used: 6991872, limit_maxbytes: 134217728, used_pct: 5.21, ...},
#   connections: %{curr_connections: 3, max_connections: 1024, ...},
#   slabs: [%{slab_id: 1, chunk_size: 96, total_chunks: 10922, used_chunks: 1216, ...}]
# }
```

### 2. `OpenUITUI.LLMTelemetry.Parser` ([`lib/openui_tui/llm_telemetry/parser.ex`](lib/openui_tui/llm_telemetry/parser.ex))

Reads `priv/telemetry/events.jsonl` and `OpenUITUI.SpendGuard` to power `StreamSource("openui_telemetry", "local", 1000)` with real Gemini & TypeSafe Jev call counts, L1/L2 cache hit rates, token breakdowns, and budget utilization.

---

## Project Structure

| Path | Description |
| :--- | :--- |
| [`lib/openui_tui.ex`](lib/openui_tui.ex) | Top-level public API (`parse_and_evaluate/2`, `render/2`, `generate_tui/2`, `resolve_and_render_80col/2`) |
| [`lib/openui_tui/config.ex`](lib/openui_tui/config.ex) | Centralized configuration (`OPENUI_LITELLM_URL`, `OPENUI_LITELLM_API_KEY`, models, budgets) |
| [`lib/openui_tui/jido.ex`](lib/openui_tui/jido.ex) | OTP-supervised `OpenUITUI.Jido` instance |
| [`lib/openui_tui/studio/agent.ex`](lib/openui_tui/studio/agent.ex) | `Jido.Agent` orchestrating Studio chat intent classification, app creation, model switching, Q&A, and UI evolution |
| [`lib/openui_tui/studio/actions/`](lib/openui_tui/studio/actions) | `ClassifyIntent`, `CreateApp`, `SwitchModel`, `AnswerQuestion`, and `EvolveUI` `Jido.Action` modules |
| [`lib/openui_tui/studio/session.ex`](lib/openui_tui/studio/session.ex) | Stateful GenServer managing active Studio apps, chat turns, revision history, and 1Hz live polling |
| [`lib/openui_tui/studio/chrome.ex`](lib/openui_tui/studio/chrome.ex) | `antigravity-cli`-inspired terminal chrome, Jido tool trees, `/` autocomplete popup, and split-screen layout |
| [`lib/openui_tui/memcached/parser.ex`](lib/openui_tui/memcached/parser.ex) | Standalone pure-Elixir Memcached `stats` / `stats slabs` / `stats items` parser |
| [`lib/openui_tui/llm_telemetry/parser.ex`](lib/openui_tui/llm_telemetry/parser.ex) | Standalone parser for `openui_tui`'s own LiteLLM (Gemini + TypeSafe Jev) & Cachex/Memcached JSONL telemetry |
| [`lib/openui_tui/tui_renderer.ex`](lib/openui_tui/tui_renderer.ex) | Responsive Unicode box-drawing renderer (`:fixed_80`) with bordered `Panel` cards, `Sparkline`, `BarList`, `Table`, and `Form` controls |

---

## Running Tests

```bash
# Run unit & offline parser/agent tests
mix test test/openui_tui/memcached_parser_test.exs test/openui_tui/jido_agent_test.exs

# Run full suite (including live LiteLLM + Memcached integration tests when configured)
mix test
```

---

## License

MIT
