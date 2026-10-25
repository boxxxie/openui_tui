defmodule OpenUITUI.Studio.Actions.ClassifyIntent do
  @moduledoc """
  `Jido.Action` that uses TypeSafe Jev (`/v1/decisions`) to classify a user's
  Studio prompt into one of three agent intents:
  - `"switch_model"` — switch active Gemini model or reasoning effort (e.g. `"use argon low"`)
  - `"ask_question_or_meta"` — answer a question about the UI, live metrics, or Studio without mutating OpenUI-Lang
  - `"build_or_modify_ui"` — generate or patch OpenUI-Lang statements for the active UI
  """

  use Jido.Action,
    name: "classify_studio_intent",
    description:
      "Classifies a Studio chat prompt via TypeSafe Jev into switch_model, ask_question_or_meta, or build_or_modify_ui",
    category: "routing",
    tags: ["jido", "jev", "routing", "openui"],
    vsn: "1.0.0",
    schema: [
      prompt: [type: :string, required: true, doc: "User prompt in Studio chat"],
      app_title: [type: :string, default: "OpenUI App", doc: "Active UI title"],
      has_live_stream: [type: :boolean, default: false, doc: "Whether 1Hz StreamSource is active"],
      statement_count: [type: :integer, default: 0, doc: "Number of OpenUI-Lang statements"],
      current_model: [type: :string, default: "gemini-3.8-flash", doc: "Current Gemini model"],
      current_effort: [type: :any, default: nil, doc: "Current reasoning effort"],
      llm_opts: [type: :keyword_list, default: [], doc: "Additional LiteLLM options"]
    ]

  alias OpenUITUI.{Config, LiteLLMClient}

  @impl true
  def run(params, _context) do
    prompt = String.trim(params.prompt)
    cur_model = params.current_model || Config.default_model()
    cur_effort = params.current_effort

    intent_ctx = %{
      title: params.app_title,
      has_live_stream: params.has_live_stream,
      statement_count: params.statement_count,
      current_model: cur_model
    }

    raw_intent =
      case LiteLLMClient.classify_chat_intent(prompt, intent_ctx, params.llm_opts || []) do
        {:ok, c} ->
          c

        _ ->
          %{
            intent: "build_or_modify_ui",
            target_model: "keep_current",
            reasoning_effort: "default",
            topic: "ui_code_and_components",
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
            duration_ms: 0,
            raw_cost_usd: 0.0,
            cache_status: :miss
          }
      end

    {effective_intent, new_model, new_effort} =
      resolve_model_switch(prompt, raw_intent, cur_model, cur_effort)

    badge = Config.format_model_badge(new_model, new_effort)

    {:ok,
     %{
       effective_intent: effective_intent,
       topic: Map.get(raw_intent, :topic, "ui_code_and_components"),
       target_model: new_model,
       reasoning_effort: new_effort,
       model_badge: badge,
       intent_info: raw_intent,
       jido_step: %{
         action: "Jido.ClassifyIntent",
         status: "ok",
         summary: "#{effective_intent} • #{badge}"
       }
     }}
  end

  @doc """
  Resolves model switches and diagnostic questions from TypeSafe Jev output and prompt keywords.
  """
  @spec resolve_model_switch(String.t(), map(), String.t(), String.t() | nil) ::
          {String.t(), String.t(), String.t() | nil}
  def resolve_model_switch(prompt, intent_info, cur_model, cur_effort) do
    down = String.downcase(String.trim(prompt))
    jev_target = Map.get(intent_info, :target_model, "keep_current")
    jev_effort = Map.get(intent_info, :reasoning_effort, "default")
    jev_intent = Map.get(intent_info, :intent, "build_or_modify_ui")

    detected_model =
      cond do
        jev_target != "keep_current" and not is_nil(jev_target) ->
          jev_target

        String.contains?(down, "argon") or String.contains?(down, "gemini-4") or
            String.contains?(down, "gemini 4") ->
          "gemini-4-argon"

        String.contains?(down, "3.8") ->
          "gemini-3.8-flash"

        String.contains?(down, "3.7") ->
          "gemini-3.7-flash"

        String.contains?(down, "3.6") ->
          "gemini-3.6-flash"

        String.contains?(down, "3.5-flash-lite") or String.contains?(down, "3.5 lite") or
            String.contains?(down, "3.5 flash lite") ->
          "gemini-3.5-flash-lite"

        String.contains?(down, "3.5") ->
          "gemini-3.5-flash"

        String.contains?(down, "3.1-flash-lite") or String.contains?(down, "3.1 lite") ->
          "gemini-3.1-flash-lite"

        String.contains?(down, "3.1") ->
          "gemini-3.1-pro"

        String.contains?(down, "2.5-flash-lite") or String.contains?(down, "2.5 lite") or
            String.contains?(down, "2.5 flash lite") ->
          "gemini-2.5-flash-lite"

        String.contains?(down, "2.5-pro") or String.contains?(down, "2.5 pro") ->
          "gemini-2.5-pro"

        String.contains?(down, "2.5") ->
          "gemini-2.5-flash"

        true ->
          nil
      end

    detected_effort =
      cond do
        jev_effort in ["low", "medium", "high"] ->
          jev_effort

        Regex.match?(~r/\blow\b/, down) ->
          "low"

        Regex.match?(~r/\bmedium\b/, down) ->
          "medium"

        Regex.match?(~r/\bhigh\b/, down) ->
          "high"

        true ->
          nil
      end

    new_model = detected_model || cur_model

    new_effort =
      cond do
        not is_nil(detected_effort) ->
          detected_effort

        detected_model == "gemini-4-argon" ->
          "low"

        not is_nil(detected_model) ->
          nil

        true ->
          cur_effort
      end

    pure_switch? =
      jev_intent == "switch_model" or
        (not is_nil(detected_model) and String.length(down) <= 36 and
           Regex.match?(~r/^(use|switch|set|model|change)\b/, down))

    create_new_app? =
      jev_intent == "create_new_app" or
        Regex.match?(
          ~r/\b(make|create|start|build|add|open|spin up)\s+(a\s+|an\s+)?new\s+(app|ui|dashboard|screen|view|project)\b/,
          down
        ) or
        Regex.match?(
          ~r/^(new\s+(app|ui|dashboard)|make\s+(a\s+|an\s+)?app\s+for\b|create\s+(a\s+|an\s+)?app\s+for\b)/,
          down
        )

    diag_question? =
      String.starts_with?(down, "analyze eviction pressure") or
        String.starts_with?(down, "diagnose slab") or
        String.starts_with?(down, "audit model") or
        String.starts_with?(down, "analyze token") or
        String.starts_with?(down, "why ") or
        String.starts_with?(down, "how ") or
        String.starts_with?(down, "what ") or
        String.starts_with?(down, "are we ") or
        String.starts_with?(down, "do we ")

    eff_intent =
      cond do
        pure_switch? -> "switch_model"
        create_new_app? -> "create_new_app"
        diag_question? -> "ask_question_or_meta"
        true -> jev_intent
      end

    {eff_intent, new_model, new_effort}
  end
end
