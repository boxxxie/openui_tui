defmodule OpenUITUI.Studio.Actions.SwitchModel do
  @moduledoc """
  `Jido.Action` that switches the active Gemini model and optional `reasoning_effort`
  (`"low"`, `"medium"`, `"high"`) for the Studio agent session.
  """

  use Jido.Action,
    name: "switch_studio_model",
    description:
      "Switches the active Gemini model and reasoning effort on the OpenUI Studio Jido agent",
    category: "configuration",
    tags: ["jido", "model", "gemini", "argon"],
    vsn: "1.0.0",
    schema: [
      prompt: [type: :string, required: true],
      target_model: [type: :string, required: true],
      reasoning_effort: [type: :any, default: nil],
      revision: [type: :integer, default: 1],
      statement_count: [type: :integer, default: 0],
      intent_info: [type: :map, default: %{}]
    ]

  alias OpenUITUI.Config

  @impl true
  def run(params, _context) do
    new_model = params.target_model
    new_effort = params.reasoning_effort
    badge = Config.format_model_badge(new_model, new_effort)
    rev = params.revision || 1
    intent_info = params.intent_info || %{}

    prompt_tok = Map.get(intent_info, :prompt_tokens, 0)
    comp_tok = Map.get(intent_info, :completion_tokens, 0)
    total_tok = prompt_tok + comp_tok
    dur_ms = Map.get(intent_info, :duration_ms, 0)
    raw_cost = Map.get(intent_info, :raw_cost_usd, 0.0)
    models_str = Enum.join(Config.supported_gemini_models(), ", ")

    effort_note =
      if new_effort in ["low", "medium", "high"] do
        " with `reasoning_effort: \"#{new_effort}\"`"
      else
        ""
      end

    answer_text =
      "Switched active model to **#{badge}** via Jido + TypeSafe Jev#{effort_note}.\n" <>
        "• Active Model: `#{badge}` (UI v#{rev} unchanged)\n" <>
        "• Supported Gemini Models: #{models_str}"

    meta = %{
      "revision" => rev,
      "statement_count" => params.statement_count || 0,
      "cache_status" => to_string(Map.get(intent_info, :cache_status, "miss")),
      "prompt_tokens" => prompt_tok,
      "completion_tokens" => comp_tok,
      "total_tokens" => total_tok,
      "cost_usd" => 0.0,
      "raw_cost_usd" => raw_cost,
      "duration_ms" => dur_ms,
      "model" => badge,
      "jev_intent" => "switch_model",
      "jev_topic" => "studio_usage_and_meta",
      "jido_actions" => [
        %{"name" => "Jido.ClassifyIntent", "detail" => "switch_model ➔ #{badge}"},
        %{"name" => "Jido.SwitchModel", "detail" => badge}
      ]
    }

    {:ok,
     %{
       model: new_model,
       reasoning_effort: new_effort,
       model_badge: badge,
       answer_text: answer_text,
       meta: meta,
       prompt_tokens: prompt_tok,
       completion_tokens: comp_tok,
       total_tokens: total_tok,
       effective_cost_usd: 0.0
     }}
  end
end
