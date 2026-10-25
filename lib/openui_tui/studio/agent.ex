defmodule OpenUITUI.Studio.Agent do
  @moduledoc """
  Declarative `Jido.Agent` representing the per-UI AI assistant inside OpenUI Studio.

  Each UI conversation in OpenUI Studio uses `OpenUITUI.Studio.Agent` to execute
  validated `Jido.Action` workflows via `Jido.Exec.run/3` and `cmd/2`:

  1. `OpenUITUI.Studio.Actions.ClassifyIntent` — TypeSafe Jev intent & model router
  2. `OpenUITUI.Studio.Actions.SwitchModel` — Switches active Gemini model & reasoning effort
  3. `OpenUITUI.Studio.Actions.AnswerQuestion` — Answers live telemetry & Studio meta questions
  4. `OpenUITUI.Studio.Actions.EvolveUI` — Generates and patches OpenUI-Lang AST statements
  """

  use Jido.Agent,
    name: "openui_studio_agent",
    description:
      "Autonomous Jido agent for OpenUI Studio TUI generation, live telemetry Q&A, and model routing",
    schema: [
      app_id: [type: :string, default: "memcached-live"],
      model: [type: :string, default: "gemini-3.8-flash"],
      reasoning_effort: [type: :any, default: nil],
      revision: [type: :integer, default: 1],
      last_intent: [type: :string, default: "idle"],
      last_topic: [type: :string, default: "none"],
      turns: [type: :integer, default: 0]
    ]

  alias Jido.Exec

  alias OpenUITUI.Studio.Actions.{
    AnswerQuestion,
    ClassifyIntent,
    CreateApp,
    EvolveUI,
    SwitchModel
  }

  @doc """
  Creates a new `OpenUITUI.Studio.Agent` struct initialized for the given app and model.
  """
  @spec new_for_app(map(), String.t(), String.t() | nil) :: Jido.Agent.t()
  def new_for_app(app, model, reasoning_effort \\ nil) when is_map(app) do
    app_id = Map.get(app, "id", "studio-app")
    rev = Map.get(app, "revision", 1)

    new(
      id: "studio-agent-#{app_id}",
      state: %{
        app_id: app_id,
        model: model,
        reasoning_effort: reasoning_effort,
        revision: rev,
        last_intent: "idle",
        last_topic: "none",
        turns: length(Map.get(app, "messages", []))
      }
    )
  end

  @doc """
  Executes `OpenUITUI.Studio.Actions.ClassifyIntent` via `Jido.Exec.run/3` and updates
  the `Jido.Agent` state.
  """
  @spec classify(Jido.Agent.t(), map()) :: {:ok, Jido.Agent.t(), map()} | {:error, term()}
  def classify(%Jido.Agent{} = agent, params) when is_map(params) do
    case Exec.run(ClassifyIntent, params, %{agent_id: agent.id}, timeout: 30_000) do
      {:ok, result} ->
        {:ok, updated_agent} =
          set(agent, %{
            model: result.target_model,
            reasoning_effort: result.reasoning_effort,
            last_intent: result.effective_intent,
            last_topic: result.topic
          })

        {:ok, updated_agent, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes `OpenUITUI.Studio.Actions.SwitchModel` via `Jido.Exec.run/3` and updates
  the `Jido.Agent` state.
  """
  @spec switch_model(Jido.Agent.t(), map()) :: {:ok, Jido.Agent.t(), map()} | {:error, term()}
  def switch_model(%Jido.Agent{} = agent, params) when is_map(params) do
    case Exec.run(SwitchModel, params, %{agent_id: agent.id}, timeout: 15_000) do
      {:ok, result} ->
        {:ok, updated_agent} =
          set(agent, %{
            model: result.model,
            reasoning_effort: result.reasoning_effort,
            turns: (agent.state[:turns] || 0) + 1
          })

        {:ok, updated_agent, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes `OpenUITUI.Studio.Actions.AnswerQuestion` via `Jido.Exec.run/3` and updates
  the `Jido.Agent` state.
  """
  @spec answer_question(Jido.Agent.t(), map()) :: {:ok, Jido.Agent.t(), map()} | {:error, term()}
  def answer_question(%Jido.Agent{} = agent, params) when is_map(params) do
    case Exec.run(AnswerQuestion, params, %{agent_id: agent.id}, timeout: 60_000) do
      {:ok, result} ->
        {:ok, updated_agent} =
          set(agent, %{
            model: result.model,
            reasoning_effort: result.reasoning_effort,
            turns: (agent.state[:turns] || 0) + 1
          })

        {:ok, updated_agent, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes `OpenUITUI.Studio.Actions.EvolveUI` via `Jido.Exec.run/3` and updates
  the `Jido.Agent` state.
  """
  @spec evolve_ui(Jido.Agent.t(), map()) :: {:ok, Jido.Agent.t(), map()} | {:error, term()}
  def evolve_ui(%Jido.Agent{} = agent, params) when is_map(params) do
    case Exec.run(EvolveUI, params, %{agent_id: agent.id}, timeout: 60_000) do
      {:ok, result} ->
        {:ok, updated_agent} =
          set(agent, %{
            model: result.model,
            reasoning_effort: result.reasoning_effort,
            revision: (agent.state[:revision] || 1) + 1,
            turns: (agent.state[:turns] || 0) + 1
          })

        {:ok, updated_agent, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes `OpenUITUI.Studio.Actions.CreateApp` via `Jido.Exec.run/3` to create a
  new App with its own dedicated chat workspace.
  """
  @spec create_app(Jido.Agent.t(), map()) :: {:ok, Jido.Agent.t(), map()} | {:error, term()}
  def create_app(%Jido.Agent{} = agent, params) when is_map(params) do
    case Exec.run(CreateApp, params, %{agent_id: agent.id}, timeout: 60_000) do
      {:ok, result} ->
        {:ok, updated_agent} =
          set(agent, %{
            model: result.model,
            reasoning_effort: result.reasoning_effort,
            revision: 1,
            turns: 1
          })

        {:ok, updated_agent, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the list of `Jido.Action` tool specifications registered for the Studio agent.
  """
  @spec registered_tools() :: [map()]
  def registered_tools do
    [
      ClassifyIntent.to_tool(),
      CreateApp.to_tool(),
      SwitchModel.to_tool(),
      AnswerQuestion.to_tool(),
      EvolveUI.to_tool()
    ]
  end
end
