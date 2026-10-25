defmodule OpenUITUI.Studio.Actions.EvolveUI do
  @moduledoc """
  `Jido.Action` that generates or incrementally patches OpenUI-Lang code for the
  active Studio UI using the selected Gemini model on LiteLLM.
  """

  use Jido.Action,
    name: "evolve_openui_ast",
    description:
      "Generates or incrementally patches OpenUI-Lang AST statements for the active Studio UI",
    category: "ui_generation",
    tags: ["jido", "openui", "ast", "tui"],
    vsn: "1.0.0",
    schema: [
      contextual_prompt: [type: :string, required: true],
      model: [type: :string, required: true],
      reasoning_effort: [type: :any, default: nil],
      intent_info: [type: :map, default: %{}],
      llm_opts: [type: :keyword_list, default: []]
    ]

  alias OpenUITUI.{Config, LiteLLMClient}

  @impl true
  def run(params, _context) do
    call_opts =
      (params.llm_opts || [])
      |> Keyword.put(:model, params.model)
      |> Keyword.put(:reasoning_effort, params.reasoning_effort)

    case LiteLLMClient.generate_openui(params.contextual_prompt, call_opts) do
      {:ok, llm_res} ->
        intent_info = params.intent_info || %{}
        topic = Map.get(intent_info, :topic, "ui_code_and_components")

        badge =
          Config.format_model_badge(
            Map.get(llm_res, :model, params.model),
            params.reasoning_effort
          )

        {:ok,
         %{
           llm_res: llm_res,
           model: params.model,
           reasoning_effort: params.reasoning_effort,
           model_badge: badge,
           jido_actions: [
             %{
               "name" => "Jido.ClassifyIntent",
               "detail" => "build_or_modify_ui (#{topic})"
             },
             %{
               "name" => "Jido.EvolveUI",
               "detail" => "#{badge} • #{Map.get(llm_res, :total_tokens, 0)} tok"
             }
           ]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
