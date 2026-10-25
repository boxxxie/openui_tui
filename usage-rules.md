# OpenUITUI Usage Rules

Rules and architectural conventions for working with `openui_tui` (OpenUI Lang Elixir TUI Maker).

## 1. LiteLLM & Spend Guardrails (`$1.00` Cap)

- **Use a scoped virtual key**: Configure `OpenUITUI.Config.api_key/0` (via `OPENUI_LITELLM_API_KEY` or `config/local.secret.exs`) against your LiteLLM Proxy (`OPENUI_LITELLM_URL`, default `http://localhost:4000`) with a `$1.00` `max_budget`.
- **Default to Gemini 3.8 Flash & TypeSafe Jev**:
  - Use `gemini-3.8-flash` (or `gemini-4-argon`, `gemini-2.5-flash-lite`) for OpenUI Lang code generation (`OpenUITUI.LiteLLMClient.generate_openui/2`).
  - Use `typesafe/jev-latest` (`OpenUITUI.LiteLLMClient.route_tui_request/2`) for SystemOne classification, layout archetype selection, and renderer recommendation. Per project rules, `jev` calls are treated as close-to-free (`effective_cost_usd = 0.0`).
- **Handle `{:error, {:budget_exceeded, report}}`**: When `OpenUITUI.SpendGuard` detects that cumulative Gemini spend has reached the `$1.00` cap, it blocks uncached Gemini calls and generates a Markdown + OpenUI TUI report via `OpenUITUI.SpendReport.generate_and_save!/1` in `priv/reports/`.

## 2. Two-Tier Caching (`Cachex` L1 + `Memcached` L2)

- Always route API calls through `OpenUITUI.LiteLLMClient` so requests check:
  1. **L1 (`Cachex` `:openui_tui_cache`)** — in-memory ETS cache.
  2. **L2 (`OpenUITUI.Memcached` on `127.0.0.1:11211`)** — persistent system-wide Memcached daemon.
- Keep `temperature: 0.0` (the default) for deterministic cache keys across runs.

## 3. Version-Tagged JSONL Telemetry

- Before testing a new prompt structure or program change, tag the session via `OpenUITUI.set_version_tags/1`:
  ```elixir
  OpenUITUI.set_version_tags(
    program_version: "0.2.0-jev-routed",
    prompt_version: "v2-jev-compact",
    experiment_tag: "compact-catalog-experiment"
  )
  ```
- Inspect historical events in `priv/telemetry/events.jsonl` or call `OpenUITUI.compare_versions/1` to compare cache hit rates, average tokens/call, latency, and USD spend across version cohorts.

## 4. 80-Column Fixed-Width Rendering & Layout Guard (`:fixed_80`)

- Use `OpenUITUI.render_code(openui_code, :fixed_80)` or `OpenUITUI.TUIRenderer.render/2` when targeting strict 80-column terminals.
- `OpenUITUI.LayoutGuard.clamp/2` automatically enforces geometry constraints before rendering:
  - Nested `Panel`s (`depth > 0`) are demoted into `Divider(title)` + `Stack(children)`.
  - `Row`s with `> 4` items or complex child containers are unwrapped into vertical `Stack`s.
  - `Table`s are capped at 4 columns and rescaled so `sum(widths) + (N - 1) * 3 <= 76`.
- `OpenUITUI.TUIRenderer` pads and truncates visible text *before* wrapping in ANSI escape codes (`fit_cell/4`), guaranteeing every border row is 80 visible graphemes wide.

## 5. Two-Loop Live Telemetry (`StreamSource` + `Bind` + `LiveSession`)

- Never re-prompt the LLM on a timer to refresh live system metrics.
- Instead, have the LLM emit `StreamSource(id, kind, target, interval_ms, format)` and `Bind($var, source_id, path, transform, template?)` statements once, and run `OpenUITUI.LiveSession` (or `OpenUITUI.Memcached.Probe` + `OpenUITUI.BindingEngine`) on the BEAM to evaluate deltas, rates, sparklines, and dynamic rows locally at 0 recurring token cost.
