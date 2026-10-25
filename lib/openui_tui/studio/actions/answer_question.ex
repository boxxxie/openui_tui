defmodule OpenUITUI.Studio.Actions.AnswerQuestion do
  @moduledoc """
  `Jido.Action` that answers a question about the current UI, live Memcached/BEAM
  telemetry, or OpenUI Studio without mutating the OpenUI-Lang AST.
  """

  use Jido.Action,
    name: "answer_studio_question",
    description:
      "Answers a question about live telemetry, OpenUI-Lang bindings, or Studio usage without modifying the UI AST",
    category: "qa",
    tags: ["jido", "qa", "telemetry", "openui"],
    vsn: "1.0.0",
    schema: [
      prompt: [type: :string, required: true],
      studio_ctx: [type: :map, required: true],
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

    case LiteLLMClient.answer_studio_question(params.prompt, params.studio_ctx, call_opts) do
      {:ok, llm_res} ->
        intent_info = params.intent_info || %{}
        topic = Map.get(intent_info, :topic, "live_metrics_and_parsing")

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
               "detail" => "ask_question_or_meta (#{topic})"
             },
             %{
               "name" => "Jido.AnswerQuestion",
               "detail" => "#{badge} • #{Map.get(llm_res, :total_tokens, 0)} tok"
             }
           ]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
