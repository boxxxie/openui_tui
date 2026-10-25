defmodule OpenUITUI.Studio.Actions.CreateApp do
  @moduledoc """
  `Jido.Action` that creates a brand-new Studio App with its own isolated Chat
  conversation, adds it to the App list, and switches the active Studio workspace
  to the new App (leaving the previous App untouched).

  Supports:
  1. Bare creation prompts (`"make new app"`, `"create a new app"`, `"new app"`)
     ➔ creates a clean starter App with its own fresh chat.
  2. `openui_tui` LLM / LiteLLM / TypeSafe Jev telemetry prompts (`"make a new app for llm metrics for the openui_tui app itself"`)
     ➔ creates a live 1Hz `StreamSource("openui_telemetry", "local", 1000)` App bound to real `priv/telemetry/events.jsonl` and `OpenUITUI.SpendGuard` metrics for Gemini & TypeSafe Jev.
  3. Topic-specific creation prompts (`"make a new app for ..."`)
     ➔ creates a new App with its own fresh chat and generates the initial `v1` OpenUI AST.
  """

  use Jido.Action,
    name: "create_studio_app",
    description:
      "Creates a new OpenUI Studio App with its own dedicated chat conversation and adds it to the app list",
    category: "app_management",
    tags: ["jido", "app", "create", "openui"],
    vsn: "1.0.0",
    schema: [
      prompt: [type: :string, required: true],
      next_app_number: [type: :integer, default: 4],
      model: [type: :string, default: "gemini-3.8-flash"],
      reasoning_effort: [type: :any, default: nil],
      intent_info: [type: :map, default: %{}],
      llm_opts: [type: :keyword_list, default: []]
    ]

  alias OpenUITUI.{Config, LiteLLMClient}

  @llm_telemetry_openui_code """
  root = Dashboard("OpenUI TUI — LiteLLM & Jev Telemetry", "LiteLLM Proxy • priv/telemetry/events.jsonl", [s_llm, s_beam, b_ram, b_procs, kpis, ops_row, p_models, ctrl_form])
  s_llm = StreamSource("openui_telemetry", "local", 1000)
  s_beam = StreamSource("beam", "beam", "erlang:memory", "term", 1000)
  b_ram = Bind($beam_ram, "beam", "total_mb", "value", "BEAM: {val}MB")
  b_procs = Bind($beam_procs, "beam", "process_count", "value", "{val} procs")
  $model_inspect = "gemini-3.8-flash"
  kpis = Row([calls_stat, cache_stat, spend_stat])
  calls_stat = Stat("1. API Calls & Tok", $llm_calls_kpi, $llm_tokens_kpi, tok_spark)
  tok_spark = Sparkline($llm_tokens_history, "info")
  cache_stat = Stat("2. L1/L2 Cache Hit", $llm_cache_kpi, $llm_cache_sub)
  spend_stat = Stat("3. LiteLLM Spend", $llm_spend_kpi, $llm_spend_sub, lat_spark)
  lat_spark = Sparkline($llm_latency_history, "ok")
  ops_row = Row([p_spend, p_pipe])
  p_spend = Panel("1-2. LiteLLM Proxy & SpendGuard ($1.00 Cap)", [spend_kv], "info")
  spend_kv = KV($llm_spend_kv)
  p_pipe = Panel("3-4. Cache Tiers (Cachex/Memcached) & AST Parser", [pipe_kv], "ok")
  pipe_kv = KV($llm_pipeline_kv)
  p_models = Panel("5. Gemini & TypeSafe Jev Model Telemetry (events.jsonl)", [models_tbl], "info")
  models_tbl = Table([c_model, c_calls, c_tokens, c_cost], $llm_model_rows, $llm_summary_footer)
  c_model = Col("Model (LiteLLM)", 20, "left")
  c_calls = Col("Calls (Hit%)", 15, "right")
  c_tokens = Col("Tokens (In/Out)", 17, "right")
  c_cost = Col("Billed / Saved $", 22, "right")
  ctrl_form = Form([f_model], [btn_audit])
  f_model = Select("Target Model", $model_inspect, $llm_model_ids)
  btn_audit = Button("Audit Model", @ToAssistant("Analyze token efficiency, cache hit rate, and latency for " + $model_inspect))
  """

  @doc """
  Returns the canonical 5-section OpenUI-Lang program for `openui_tui`'s own
  LiteLLM (Gemini + TypeSafe Jev) & Cachex/Memcached telemetry dashboard.
  """
  @spec llm_telemetry_openui_code() :: String.t()
  def llm_telemetry_openui_code, do: String.trim(@llm_telemetry_openui_code)

  @impl true
  def run(params, _context) do
    prompt = String.trim(params.prompt)
    down = String.downcase(prompt)
    model = params.model || Config.default_model()
    effort = params.reasoning_effort
    badge = Config.format_model_badge(model, effort)
    next_num = params.next_app_number || 4

    cond do
      llm_telemetry_request?(down) ->
        title = "OpenUI TUI — LiteLLM & Jev Telemetry"

        note =
          "Created new App **\"#{title}\"** (added to the App list with its own fresh chat) streaming real 1Hz telemetry from `priv/telemetry/events.jsonl` and `OpenUITUI.SpendGuard` via `StreamSource(\"openui_telemetry\", \"local\", 1000)`.\n" <>
            "• Models Tracked: Google Gemini (`gemini-3.8-flash`, `gemini-4-argon`, `gemini-2.5-flash-lite`) + TypeSafe Jev (`typesafe/jev-latest`) via LiteLLM (`#{Config.litellm_url()}`).\n" <>
            "• Live Sources: `openui_telemetry(events.jsonl+SpendGuard)` + `beam(erlang:memory)` at 1Hz."

        {:ok,
         %{
           mode: :seeded_llm_telemetry,
           title: title,
           openui_code: llm_telemetry_openui_code(),
           ui_state: %{"$model_inspect" => "gemini-3.8-flash"},
           assistant_note: note,
           model: model,
           reasoning_effort: effort,
           model_badge: badge,
           llm_res: nil
         }}

      bare_new_app_request?(down) ->
        title = extract_requested_title(prompt, next_num)

        code = """
        root = Dashboard(#{inspect(title)}, "New OpenUI App — describe what to build in Chat", [
          Alert("info", "Created new app workspace '#{title}' with its own isolated chat! Describe what you want to build below."),
          Row([
            Stat("App Status", "Ready (v1)", "Fresh Chat"),
            Stat("Active Model", #{inspect(badge)}, "Jido + Jev"),
            Stat("Renderer", "fixed_80", "1Hz Ready")
          ])
        ])
        """

        note =
          "Created new App **\"#{title}\"** and switched to its dedicated Chat workspace. Describe the dashboard, live metrics, or controls you want to build for this app!"

        {:ok,
         %{
           mode: :blank_starter,
           title: title,
           openui_code: String.trim(code),
           ui_state: %{},
           assistant_note: note,
           model: model,
           reasoning_effort: effort,
           model_badge: badge,
           llm_res: nil
         }}

      true ->
        call_opts =
          (params.llm_opts || [])
          |> Keyword.put(:model, model)
          |> Keyword.put(:reasoning_effort, effort)

        case LiteLLMClient.generate_openui(prompt, call_opts) do
          {:ok, llm_res} ->
            title = extract_requested_title(prompt, next_num)

            {:ok,
             %{
               mode: :generated,
               title: title,
               openui_code: nil,
               ui_state: %{},
               assistant_note: nil,
               model: model,
               reasoning_effort: effort,
               model_badge: badge,
               llm_res: llm_res
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Checks whether a prompt is asking for an LLM / LiteLLM / Jev / token / telemetry
  dashboard for `openui_tui`.
  """
  @spec llm_telemetry_request?(String.t()) :: boolean()
  def llm_telemetry_request?(down) when is_binary(down) do
    (String.contains?(down, "llm") or String.contains?(down, "litellm") or
       String.contains?(down, "jev") or String.contains?(down, "token") or
       String.contains?(down, "spend") or String.contains?(down, "telemetry")) and
      (String.contains?(down, "metric") or String.contains?(down, "openui") or
         String.contains?(down, "tui") or String.contains?(down, "app") or
         String.contains?(down, "dashboard") or String.contains?(down, "telemetry") or
         String.contains?(down, "call") or String.contains?(down, "cost"))
  end

  defp bare_new_app_request?(down) do
    cleaned =
      down
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.trim()

    cleaned in [
      "make new app",
      "make a new app",
      "create new app",
      "create a new app",
      "new app",
      "start new app",
      "start a new app",
      "add new app",
      "add a new app",
      "make new ui",
      "create new ui",
      "new ui"
    ] or
      Regex.match?(
        ~r/^(make|create|start|add)\s+(a\s+)?new\s+(app|ui)\s+(called|named)\s+\S+$/,
        cleaned
      )
  end

  defp extract_requested_title(prompt, next_num) do
    case Regex.run(~r/(?:called|named|titled)\s+["']?([^"'\n]+)["']?/i, prompt) do
      [_, name] ->
        String.trim(name)

      _ ->
        case Regex.run(~r/\bnew\s+(?:app|ui|dashboard)\s+for\s+(.+)$/i, prompt) do
          [_, topic] ->
            topic
            |> String.trim()
            |> String.slice(0, 36)
            |> String.split(~r/\s+/)
            |> Enum.map_join(" ", &String.capitalize/1)

          _ ->
            "New OpenUI App ##{next_num}"
        end
    end
  end
end
