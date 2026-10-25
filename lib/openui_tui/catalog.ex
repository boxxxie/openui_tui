defmodule OpenUITUI.Catalog do
  @moduledoc """
  Defines the OpenUI 1.0 TUI Component Library Schema (`Dashboard`, `Panel`, `Row`,
  `Stack`, `Divider`, `KV`, `Stat`, `Sparkline`, `BarList`, `BarItem`, `Alert`,
  `Progress`, `Table`, `Col`, `Badge`, `KeyValue`, `Text`, `Form`, `Field`,
  `Select`, `Toggle`, `Button`, `StreamSource`, `Bind`) and provides versioned
  system prompts (`v1-full-prompt`, `v2-jev-compact`, `v3-80col-strict`) for
  telemetry benchmarking.
  """

  alias OpenUITUI.Telemetry

  @external_resource Path.expand("../../priv/prompts/openui_tui_system.txt", __DIR__)
  @strict_80col_prompt File.read!(
                         Path.expand("../../priv/prompts/openui_tui_system.txt", __DIR__)
                       )

  @any_component_refs """
  [
    { "$ref": "#/$defs/Dashboard" },
    { "$ref": "#/$defs/Row" },
    { "$ref": "#/$defs/Stack" },
    { "$ref": "#/$defs/Panel" },
    { "$ref": "#/$defs/Divider" },
    { "$ref": "#/$defs/KV" },
    { "$ref": "#/$defs/Stat" },
    { "$ref": "#/$defs/Sparkline" },
    { "$ref": "#/$defs/BarList" },
    { "$ref": "#/$defs/BarItem" },
    { "$ref": "#/$defs/Alert" },
    { "$ref": "#/$defs/Progress" },
    { "$ref": "#/$defs/Table" },
    { "$ref": "#/$defs/Col" },
    { "$ref": "#/$defs/Badge" },
    { "$ref": "#/$defs/KeyValue" },
    { "$ref": "#/$defs/Text" },
    { "$ref": "#/$defs/Form" },
    { "$ref": "#/$defs/Field" },
    { "$ref": "#/$defs/Select" },
    { "$ref": "#/$defs/Toggle" },
    { "$ref": "#/$defs/Button" },
    { "$ref": "#/$defs/StreamSource" },
    { "$ref": "#/$defs/Bind" }
  ]
  """

  @raw_library_json """
  {
    "id": "openui-tui",
    "version": "1.0.0",
    "root": "Dashboard",
    "components": {
      "Dashboard": { "description": "Top-level terminal dashboard screen" },
      "Row": { "description": "Horizontal row of KPI stats or badges (max 3 Stat cards)" },
      "Stack": { "description": "Vertical stack of TUI sections" },
      "Panel": { "description": "Bordered panel with a title and list of children or bullet lines" },
      "Divider": { "description": "Horizontal section rule (─── Label ────)" },
      "KV": { "description": "Compact 2-column key-value list ([['Key', 'Value'], ...])" },
      "Stat": { "description": "KPI metric box with label, value, trend/hint, and optional Sparkline" },
      "Sparkline": { "description": "Single-line 8-level Unicode block chart (▁▂▃▄▅▆▇█)" },
      "BarList": { "description": "Horizontal 1/8th fractional bar chart" },
      "BarItem": { "description": "Single horizontal bar item (label, value, text)" },
      "Alert": { "description": "Colored status banner (info, success, warning, error)" },
      "Progress": { "description": "Horizontal progress/utilization bar (0..100)" },
      "Table": { "description": "Columnar or row-based data table (max 4 Col definitions)" },
      "Col": { "description": "Single table column definition" },
      "Badge": { "description": "Inline colored status tag" },
      "KeyValue": { "description": "Key-value metadata object display" },
      "Text": { "description": "Single text line" },
      "Form": { "description": "Interactive form container with fields and buttons" },
      "Field": { "description": "Single-line text input bound to a $var", "bindable": true },
      "Select": { "description": "Single-line inline option cycler bound to a $var", "bindable": true },
      "Toggle": { "description": "Single-line checkbox bound to a $boolean_var", "bindable": true },
      "Button": { "description": "Interactive command hint / action button" },
      "StreamSource": { "description": "Real-time data plane poller (memcached, beam, exec)" },
      "Bind": { "description": "Reactive variable binding from a StreamSource" }
    },
    "schema": {
      "properties": {
        "Dashboard": { "$ref": "#/$defs/Dashboard" },
        "Row": { "$ref": "#/$defs/Row" },
        "Stack": { "$ref": "#/$defs/Stack" },
        "Panel": { "$ref": "#/$defs/Panel" },
        "Divider": { "$ref": "#/$defs/Divider" },
        "KV": { "$ref": "#/$defs/KV" },
        "Stat": { "$ref": "#/$defs/Stat" },
        "Sparkline": { "$ref": "#/$defs/Sparkline" },
        "BarList": { "$ref": "#/$defs/BarList" },
        "BarItem": { "$ref": "#/$defs/BarItem" },
        "Alert": { "$ref": "#/$defs/Alert" },
        "Progress": { "$ref": "#/$defs/Progress" },
        "Table": { "$ref": "#/$defs/Table" },
        "Col": { "$ref": "#/$defs/Col" },
        "Badge": { "$ref": "#/$defs/Badge" },
        "KeyValue": { "$ref": "#/$defs/KeyValue" },
        "Text": { "$ref": "#/$defs/Text" },
        "Form": { "$ref": "#/$defs/Form" },
        "Field": { "$ref": "#/$defs/Field" },
        "Select": { "$ref": "#/$defs/Select" },
        "Toggle": { "$ref": "#/$defs/Toggle" },
        "Button": { "$ref": "#/$defs/Button" },
        "StreamSource": { "$ref": "#/$defs/StreamSource" },
        "Bind": { "$ref": "#/$defs/Bind" }
      },
      "$defs": {
        "Dashboard": {
          "type": "object",
          "description": "Top-level terminal dashboard screen",
          "properties": {
            "title": { "type": "string" },
            "subtitle": { "type": "string" },
            "children": { "type": "array", "items": { "anyOf": #{@any_component_refs} } }
          },
          "required": ["title", "subtitle", "children"]
        },
        "Row": {
          "type": "object",
          "description": "Horizontal row of KPI stats or badges",
          "properties": {
            "children": { "type": "array", "items": { "anyOf": #{@any_component_refs} } }
          },
          "required": ["children"]
        },
        "Stack": {
          "type": "object",
          "description": "Vertical stack of TUI sections",
          "properties": {
            "children": { "type": "array", "items": { "anyOf": #{@any_component_refs} } },
            "gap": { "type": "number" }
          },
          "required": ["children"]
        },
        "Panel": {
          "type": "object",
          "description": "Bordered panel with a title and list of bullet lines or child components",
          "properties": {
            "title": { "type": "string" },
            "items": { "type": "array" },
            "tone": { "type": "string" }
          },
          "required": ["title", "items"]
        },
        "Divider": {
          "type": "object",
          "description": "Horizontal rule with optional label",
          "properties": {
            "label": { "type": "string" }
          }
        },
        "KV": {
          "type": "object",
          "description": "2-column key-value pairs",
          "properties": {
            "pairs": { "type": "array" }
          },
          "required": ["pairs"]
        },
        "Stat": {
          "type": "object",
          "description": "KPI metric box with label, value, trend/hint, and optional Sparkline",
          "properties": {
            "label": { "type": "string" },
            "value": { "type": "string" },
            "hint": { "type": "string" },
            "spark": { "$ref": "#/$defs/Sparkline" }
          },
          "required": ["label", "value"]
        },
        "Sparkline": {
          "type": "object",
          "description": "Single-line Unicode block chart (▁▂▃▄▅▆▇█)",
          "properties": {
            "points": { "type": "array", "items": { "type": "number" } },
            "tone": { "type": "string" }
          },
          "required": ["points"]
        },
        "BarList": {
          "type": "object",
          "description": "Horizontal 1/8th fractional bar chart",
          "properties": {
            "items": { "type": "array", "items": { "$ref": "#/$defs/BarItem" } }
          },
          "required": ["items"]
        },
        "BarItem": {
          "type": "object",
          "description": "Single horizontal bar item",
          "properties": {
            "label": { "type": "string" },
            "value": { "type": "number" },
            "text": { "type": "string" }
          },
          "required": ["label", "value"]
        },
        "Alert": {
          "type": "object",
          "description": "Colored status banner",
          "properties": {
            "tone": { "type": "string", "enum": ["info", "success", "warning", "error"] },
            "message": { "type": "string" }
          },
          "required": ["tone", "message"]
        },
        "Progress": {
          "type": "object",
          "description": "Horizontal progress bar (0..100)",
          "properties": {
            "label": { "type": "string" },
            "percent": { "type": "number" }
          },
          "required": ["label", "percent"]
        },
        "Table": {
          "type": "object",
          "description": "Columnar or row-based data table composed of Col() definitions",
          "properties": {
            "columns": {
              "type": "array",
              "items": { "$ref": "#/$defs/Col" }
            },
            "rows": { "type": "array" },
            "footer": { "type": "string" }
          },
          "required": ["columns"]
        },
        "Col": {
          "type": "object",
          "description": "Single table column with header label and array of cell values or width/align",
          "properties": {
            "label": { "type": "string" },
            "data": {},
            "align": { "type": "string" }
          },
          "required": ["label"]
        },
        "Badge": {
          "type": "object",
          "description": "Inline colored status tag",
          "properties": {
            "label": { "type": "string" },
            "tone": { "type": "string", "enum": ["info", "success", "warning", "error"] }
          },
          "required": ["label", "tone"]
        },
        "KeyValue": {
          "type": "object",
          "description": "Key-value metadata object display",
          "properties": {
            "entries": { "type": "object" }
          },
          "required": ["entries"]
        },
        "Text": {
          "type": "object",
          "description": "Single text line",
          "properties": {
            "text": { "type": "string" },
            "style": { "type": "string" }
          },
          "required": ["text"]
        },
        "Form": {
          "type": "object",
          "description": "Interactive form container",
          "properties": {
            "fields": { "type": "array", "items": { "anyOf": [{ "$ref": "#/$defs/Field" }, { "$ref": "#/$defs/Select" }, { "$ref": "#/$defs/Toggle" }] } },
            "buttons": { "type": "array", "items": { "$ref": "#/$defs/Button" } }
          },
          "required": ["fields", "buttons"]
        },
        "Field": {
          "type": "object",
          "description": "Single-line text input",
          "properties": {
            "label": { "type": "string" },
            "binding": { "type": "string" },
            "placeholder": { "type": "string" },
            "secret": { "type": "boolean" }
          },
          "required": ["label", "binding"]
        },
        "Select": {
          "type": "object",
          "description": "Single-line inline option cycler",
          "properties": {
            "label": { "type": "string" },
            "binding": { "type": "string" },
            "options": { "type": "array", "items": { "type": "string" } }
          },
          "required": ["label", "binding", "options"]
        },
        "Toggle": {
          "type": "object",
          "description": "Single-line boolean checkbox",
          "properties": {
            "label": { "type": "string" },
            "binding": { "type": "boolean" }
          },
          "required": ["label", "binding"]
        },
        "Button": {
          "type": "object",
          "description": "Interactive command hint / action button",
          "properties": {
            "label": { "type": "string" },
            "command": {}
          },
          "required": ["label"]
        },
        "StreamSource": {
          "type": "object",
          "description": "Real-time 1Hz telemetry poller",
          "properties": {
            "source_id": { "type": "string" },
            "target_or_transport": { "type": "string" },
            "target_or_interval": {},
            "format": { "type": "string" },
            "interval_ms": { "type": "number" }
          },
          "required": ["source_id"]
        },
        "Bind": {
          "type": "object",
          "description": "Reactive binding from a StreamSource",
          "properties": {
            "target_var": {},
            "source_id": { "type": "string" },
            "field_path": {},
            "transform": { "type": "string" },
            "template": { "type": "string" }
          },
          "required": ["target_var", "source_id", "field_path"]
        }
      }
    }
  }
  """

  @spec raw_spec() :: map()
  def raw_spec do
    OpenUILang.decode_json!(@raw_library_json)
  end

  @spec compiled_schema() :: map()
  def compiled_schema do
    OpenUILang.compile_schema(raw_spec())
  end

  @spec schema_hash() :: String.t()
  def schema_hash do
    Telemetry.fingerprint(@raw_library_json)
  end

  @doc """
  Returns the canonical 80-column system prompt loaded from `priv/prompts/openui_tui_system.txt`.
  """
  @spec strict_80col_system_prompt() :: String.t()
  def strict_80col_system_prompt, do: @strict_80col_prompt

  @doc """
  Builds a system prompt for the requested `prompt_version` (`"v1-full-prompt"`,
  `"v2-jev-compact"`, or `"v3-80col-strict"`).
  """
  @spec system_prompt(String.t(), map()) :: {String.t(), String.t()}
  def system_prompt(prompt_version \\ "v2-jev-compact", jev_routing \\ %{})

  def system_prompt("v3-80col-strict", _jev_routing) do
    {@strict_80col_prompt, Telemetry.fingerprint(@strict_80col_prompt)}
  end

  def system_prompt("v1-full-prompt", _jev_routing) do
    base = OpenUILang.generate_system_prompt(raw_spec())

    prompt = """
    #{base}

    Additional TUI Rules & Examples:
    - Output ONLY valid OpenUI Lang assignments (`root = Dashboard(...)`). Do not wrap in prose.
    - Always start with `root = Dashboard(title, subtitle, [children...])`.
    - Use `Table([Col("Header", ["row1", "row2"]), ...])` for tabular data.
    - Use `Row([Stat("Label", "Value", "Hint"), ...])` for KPI metrics.
    - Use `Alert("info"|"success"|"warning"|"error", "Message")` for banners.
    - Use `Progress("Label", 75)` for percentage bars (0..100).
    - Use `Panel("Title", ["item 1", "item 2"])` for bulleted summaries.
    - Never use named arguments or missing arguments; pass positional arguments in exact signature order.
    """

    {prompt, Telemetry.fingerprint(prompt)}
  end

  def system_prompt("v2-jev-compact", jev_routing) do
    archetype = Map.get(jev_routing, :archetype, "metrics_dashboard")
    density = Map.get(jev_routing, :density, "compact")

    prompt = """
    Output ONLY OpenUI Lang statements. First line MUST be:
    root = Dashboard("Title", "Subtitle", [child1, child2])
    Archetype: #{archetype} (#{density})
    80-Col Rules: Max 3 Stat per Row; max 4 Col per Table; no Table/Form inside Row.
    Signatures (positional args only):
    Dashboard(title, subtitle, [children])
    Alert("info"|"success"|"warning"|"error", message)
    Row([Stat(label, value, hint, spark?)])
    Sparkline([numbers], tone?)
    BarList([BarItem(label, value, text?)])
    Progress(label, percent_num)
    Table([Col(label, [values])])
    Panel(title, [strings])
    Divider(label?)
    KV([[key, value]])
    """

    {prompt, Telemetry.fingerprint("v2-jev-compact:#{prompt}")}
  end

  def system_prompt(prompt_version, jev_routing) do
    archetype = Map.get(jev_routing, :archetype, "metrics_dashboard")
    density = Map.get(jev_routing, :density, "standard")

    prompt = """
    You are OpenUI Studio's TUI App Builder.
    First write 1 concise sentence explaining what you built or updated in the UI, then output a fenced ```openui code block containing the complete OpenUI Lang program.
    Archetype: #{archetype} (#{density})
    80-Col Rules: Max 3 Stat per Row; max 4 Col per Table; no Table/Form inside Row; positional args only.

    Core Visual Components:
    root = Dashboard(title, subtitle, [children...])
    Alert("info"|"success"|"warning"|"error", message)
    Row([Stat(label, value, hint, spark?)])
    Sparkline([numbers] | $live_var, "info"|"ok"|"warn"|"error")
    BarList([BarItem(label, number_0_to_100, right_text)] | $live_slab_bars)
    Progress(label, number_0_to_100)
    Table([Col(header, [col_values])])
    Table([Col(header, width_int, "left"|"right")], $live_rows_var, footer_str?)
    Panel(title, [children_or_strings], tone?)
    Divider(label?)
    KV([[key, value]])

    LIVE REAL-TIME TELEMETRY (CRITICAL: Always use StreamSource when asked for live, real-time, updating, Memcached, BEAM, or host metrics!):
    1. Live Memcached (127.0.0.1:11211 at 1Hz — Full 5-Section Operational Telemetry):
       src = StreamSource("memcached", "127.0.0.1:11211", 1000)
       Include `src` in `root`'s children list! It automatically updates these live variables every 1s:
       - KPI Row bindings:
         * Stat("1. Service & Conns", $live_service_kpi, $live_conns_kpi, Sparkline($live_ops_history, "info"))
         * Stat("2. Hit Rate & Ops", $live_hit_ratio, $live_gets_sets, Sparkline($live_hit_history, "ok"))
         * Stat("3. Memory & Items", $live_mem_short, $live_items_evict)
       - 2-Column Operational Summary Cards (`Row([Panel("1-2. Service & Cache Performance", [KV($live_service_cache_kv)], "info"), Panel("3-4. Memory Health & Network I/O", [KV($live_memory_net_kv)], "ok")])` or `Panel("Operational Summary", [KV($live_ops_kv)], "info")`):
         * Renders 1. Service/Uptime, 2. Cache Hit Rate, 3. Memory & Storage Health, and 4. Connections & Network I/O inside bordered cards.
       - Section 5 Slab Class Distribution (`Panel("5. Slab Class Distribution (Top Populated Slabs)", [Table([Col("Slab (Chunk)", 16, "left"), Col("Items", 13, "right"), Col("Pages / Pool", 14, "right"), Col("Util % / Evict", 22, "right")], $live_slab_rows, $live_uptime_footer)], "info")`):
         * $live_slab_ids (pass to Select("Target Slab", $slab_inspect, $live_slab_ids))
         * (Prefer wrapping sections in `Panel(...)` cards and using the 4-column Table over BarList($live_slab_bars) so all 5 sections fit on screen with clean borders!)
    2. Live BEAM VM (1Hz):
       s_beam = StreamSource("beam", "beam", "erlang:memory", "term", 1000)
       b_ram = Bind($beam_ram, "beam", "total_mb", "value", "BEAM: {val}MB")
       b_procs = Bind($beam_procs, "beam", "process_count", "value", "{val} procs")
       b_spark = Bind($beam_spark, "beam", "total_mb", "spark_value")
       (Include s_beam, b_ram, b_procs, b_spark in `root`'s children list!)
    3. Live Linux Host CLI (2Hz):
       s_host = StreamSource("host", "exec", "vmstat 1 2", "columns", 2000)
       b_cpu = Bind($cpu_idle, "host", "id", "value", "Idle: {val}%")
    4. Live OpenUI TUI LLM, TypeSafe Jev & LiteLLM Spend Telemetry (1Hz — `priv/telemetry/events.jsonl` + `OpenUITUI.SpendGuard`):
       CRITICAL: `openui_tui` ONLY uses Google Gemini (`gemini-3.8-flash`, `gemini-4-argon`, `gemini-3.1-pro`, `gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-2.5-flash-lite`) and TypeSafe Jev (`typesafe/jev-latest`) via the configured LiteLLM Proxy. NEVER output fake models like `gpt-4o`, `claude-3.5-sonnet`, or `mistral-large`!
       When asked for an LLM metrics, token spend, cache hit, Jev, or `openui_tui` telemetry dashboard, ALWAYS include:
       s_llm = StreamSource("openui_telemetry", "local", 1000)
       Include `s_llm` in `root`'s children list! It automatically populates these real 1Hz variables from `OpenUITUI.LLMTelemetry.Parser`:
       - KPI Row:
         * Stat("1. API Calls", $llm_calls_kpi, $llm_tokens_kpi, Sparkline($llm_tokens_history, "info"))
         * Stat("2. L1/L2 Cache", $llm_cache_kpi, $llm_cache_sub)
         * Stat("3. LiteLLM Spend", $llm_spend_kpi, $llm_spend_sub, Sparkline($llm_latency_history, "ok"))
       - 2-Column Telemetry Cards:
         * Row([Panel("1-2. LiteLLM Proxy & SpendGuard ($1.00 Cap)", [KV($llm_spend_kv)], "info"), Panel("3-4. Cache Tiers (Cachex/Memcached) & AST Parser", [KV($llm_pipeline_kv)], "ok")])
       - Per-Model Table:
         * Panel("5. Gemini & TypeSafe Jev Model Telemetry (events.jsonl)", [Table([Col("Model (LiteLLM)", 20, "left"), Col("Calls (Hit%)", 15, "right"), Col("Tokens (In/Out)", 17, "right"), Col("Billed / Saved $", 22, "right")], $llm_model_rows, $llm_summary_footer)], "info")
       - Interactive Controls:
         * Select("Target Model", $model_inspect, $llm_model_ids)
         * Button("Audit Model", @ToAssistant("Analyze token efficiency, cache hit rate, and latency for " + $model_inspect))

    INTERACTIVE CONTROLS (Always include a Form at the bottom of dashboards so the user can interact via ↑/↓/←/→/Enter):
    Declare default state variables at the top (e.g. $slab_inspect = "1", $auto_refresh = true), then include in `root`:
    Form([
      Select(label, $var, ["opt1", "opt2"] | $live_slab_ids),
      Toggle(label, $bool_var),
      Field(label, $str_var, placeholder_str)
    ], [
      Button(label, @ToAssistant("Action prompt using " + $var))
    ])
    """

    {prompt, Telemetry.fingerprint("#{prompt_version}:#{prompt}")}
  end
end
