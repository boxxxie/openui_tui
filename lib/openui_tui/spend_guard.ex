defmodule OpenUITUI.SpendGuard do
  @moduledoc """
  Real-time spend ledger and `$1.00` budget guardrail for LiteLLM API calls.

  ## Cost Accounting Rules
  - **Gemini Models (`gemini-2.5-flash-lite`, `gemini-3.5-flash-lite`, etc.)**:
    Billed at full LiteLLM `x-litellm-response-cost` toward the `$1.00` budget limit.
  - **TypeSafe Jev (`typesafe/jev-latest`, `jev`)**:
    Treated as close-to-free (`effective_cost_usd = 0.0`) for budget gating while still
    recording `raw_cost_usd` in telemetry for full visibility.
  - **Cache Hits (`Cachex` L1 / `Memcached` L2)**:
    Cost `$0.00` and increment `saved_by_cache_usd` by the original call's cost.

  ## Budget Overrun Workflow
  If cumulative effective spend reaches or exceeds `budget_limit_usd` (default `$1.00`),
  `SpendGuard` halts uncached LLM calls, emits `[:openui_tui, :budget, :exceeded]`, and
  automatically builds a human-review Spend & Learning Report via `OpenUITUI.SpendReport`.
  """

  use GenServer

  alias OpenUITUI.{Config, SpendReport, Telemetry}

  # ── Client API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks whether a live call to `model` is permitted under the active budget limit.
  Note: Jev calls (`typesafe/jev-*`) are considered close-to-free and are always allowed
  unless explicitly blocked.
  """
  @spec check_budget(String.t(), keyword()) :: :ok | {:error, {:budget_exceeded, map()}}
  def check_budget(model, opts \\ []) do
    GenServer.call(__MODULE__, {:check_budget, model, opts})
  end

  @doc """
  Records the cost of a completed API call (or simulated spend in tests) and triggers
  an automatic spend review report if the budget threshold is crossed.
  """
  @spec record_call(map()) :: {:ok, map()} | {:budget_exceeded, map()}
  def record_call(call_metrics) when is_map(call_metrics) do
    GenServer.call(__MODULE__, {:record_call, call_metrics})
  end

  @doc """
  Records cost savings from a cache hit (`:l1_cachex` or `:l2_memcached`).
  """
  @spec record_cache_saving(float(), float()) :: :ok
  def record_cache_saving(effective_saved_usd, raw_saved_usd) do
    GenServer.cast(__MODULE__, {:record_cache_saving, effective_saved_usd, raw_saved_usd})
  end

  @doc """
  Returns the current ledger state.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Queries LiteLLM `/key/info` directly to synchronize server-side key spend and `max_budget`.
  """
  @spec sync_remote_key_info() :: {:ok, map()} | {:error, term()}
  def sync_remote_key_info do
    url = Config.litellm_url() <> "/key/info"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{Config.api_key()}"}],
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"info" => info}}} ->
        GenServer.call(__MODULE__, {:sync_remote, info})

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Temporarily overrides the budget limit (useful for testing budget overrun reporting
  at e.g. `$0.000001` without spending $1.00).
  """
  @spec set_budget_limit(float()) :: :ok
  def set_budget_limit(limit_usd) when is_number(limit_usd) do
    GenServer.call(__MODULE__, {:set_budget_limit, limit_usd * 1.0})
  end

  @doc """
  Resets in-memory session spend counters (historical JSONL remains intact).
  """
  @spec reset_session!(keyword()) :: :ok
  def reset_session!(opts \\ []) do
    GenServer.call(__MODULE__, {:reset_session, opts})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    initial = bootstrap_from_jsonl()
    {:ok, initial}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_budget_limit, limit_usd}, _from, state) do
    {:reply, :ok, %{state | budget_limit_usd: limit_usd}}
  end

  @impl true
  def handle_call({:reset_session, opts}, _from, _state) do
    reloaded =
      if Keyword.get(opts, :reload_jsonl, false) do
        bootstrap_from_jsonl()
      else
        %{
          budget_limit_usd: Config.budget_limit_usd(),
          soft_budget_usd: Config.soft_budget_usd(),
          billed_gemini_spend_usd: 0.0,
          jev_raw_spend_usd: 0.0,
          total_raw_spend_usd: 0.0,
          saved_by_cache_usd: 0.0,
          saved_raw_by_cache_usd: 0.0,
          remote_key_spend_usd: 0.0,
          remote_max_budget_usd: Config.budget_limit_usd(),
          call_count: 0,
          jev_call_count: 0,
          cache_hit_count: 0,
          last_report_path: nil
        }
      end

    {:reply, :ok, reloaded}
  end

  @impl true
  def handle_call({:sync_remote, info}, _from, state) do
    remote_spend = (info["spend"] || 0.0) * 1.0
    remote_max = (info["max_budget"] || state.budget_limit_usd) * 1.0

    updated = %{
      state
      | remote_key_spend_usd: remote_spend,
        remote_max_budget_usd: remote_max
    }

    {:reply, {:ok, updated}, updated}
  end

  @impl true
  def handle_call({:check_budget, model, opts}, _from, state) do
    limit = Keyword.get(opts, :budget_limit_usd, state.budget_limit_usd)

    cond do
      Config.jev_model?(model) ->
        {:reply, :ok, state}

      state.billed_gemini_spend_usd >= limit ->
        {report, updated_state} = trigger_overrun_report(state, model, limit, "pre_call_gate")
        {:reply, {:error, {:budget_exceeded, report}}, updated_state}

      true ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:record_call, metrics}, _from, state) do
    model = Map.get(metrics, :model, "unknown")
    raw_cost = (Map.get(metrics, :raw_cost_usd, 0.0) || 0.0) * 1.0
    jev? = Config.jev_model?(model)
    effective_cost = if jev?, do: 0.0, else: raw_cost

    remote_spend =
      case Map.get(metrics, :remote_key_spend_usd) do
        n when is_number(n) -> n * 1.0
        _ -> state.remote_key_spend_usd + raw_cost
      end

    updated = %{
      state
      | billed_gemini_spend_usd: state.billed_gemini_spend_usd + effective_cost,
        jev_raw_spend_usd: state.jev_raw_spend_usd + if(jev?, do: raw_cost, else: 0.0),
        total_raw_spend_usd: state.total_raw_spend_usd + raw_cost,
        remote_key_spend_usd: remote_spend,
        call_count: state.call_count + 1,
        jev_call_count: state.jev_call_count + if(jev?, do: 1, else: 0)
    }

    if not jev? and updated.billed_gemini_spend_usd >= updated.budget_limit_usd do
      {report, reported_state} =
        trigger_overrun_report(updated, model, updated.budget_limit_usd, "post_call_threshold")

      {:reply, {:budget_exceeded, report}, reported_state}
    else
      {:reply, {:ok, updated}, updated}
    end
  end

  @impl true
  def handle_cast({:record_cache_saving, effective_saved, raw_saved}, state) do
    updated = %{
      state
      | saved_by_cache_usd: state.saved_by_cache_usd + effective_saved,
        saved_raw_by_cache_usd: state.saved_raw_by_cache_usd + raw_saved,
        cache_hit_count: state.cache_hit_count + 1
    }

    {:noreply, updated}
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────

  defp bootstrap_from_jsonl do
    events = Telemetry.read_jsonl()

    Enum.reduce(
      events,
      %{
        budget_limit_usd: Config.budget_limit_usd(),
        soft_budget_usd: Config.soft_budget_usd(),
        billed_gemini_spend_usd: 0.0,
        jev_raw_spend_usd: 0.0,
        total_raw_spend_usd: 0.0,
        saved_by_cache_usd: 0.0,
        saved_raw_by_cache_usd: 0.0,
        remote_key_spend_usd: 0.0,
        remote_max_budget_usd: Config.budget_limit_usd(),
        call_count: 0,
        jev_call_count: 0,
        cache_hit_count: 0,
        last_report_path: nil
      },
      fn ev, acc ->
        case ev["event"] do
          e when e in ["openui_tui.llm.call", "openui_tui.jev.call"] ->
            if ev["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"] do
              %{
                acc
                | saved_by_cache_usd: acc.saved_by_cache_usd + (ev["saved_cost_usd"] || 0.0),
                  saved_raw_by_cache_usd:
                    acc.saved_raw_by_cache_usd + (ev["saved_raw_cost_usd"] || 0.0),
                  cache_hit_count: acc.cache_hit_count + 1
              }
            else
              raw = (ev["raw_cost_usd"] || 0.0) * 1.0
              eff = (ev["effective_cost_usd"] || 0.0) * 1.0
              jev? = ev["event"] == "openui_tui.jev.call" or Config.jev_model?(ev["model"] || "")

              %{
                acc
                | billed_gemini_spend_usd: acc.billed_gemini_spend_usd + eff,
                  jev_raw_spend_usd: acc.jev_raw_spend_usd + if(jev?, do: raw, else: 0.0),
                  total_raw_spend_usd: acc.total_raw_spend_usd + raw,
                  call_count: acc.call_count + 1,
                  jev_call_count: acc.jev_call_count + if(jev?, do: 1, else: 0)
              }
            end

          _ ->
            acc
        end
      end
    )
  end

  defp trigger_overrun_report(state, attempted_model, limit, trigger_reason) do
    :telemetry.execute(
      [:openui_tui, :budget, :exceeded],
      %{
        billed_gemini_spend_usd: state.billed_gemini_spend_usd,
        budget_limit_usd: limit,
        saved_by_cache_usd: state.saved_by_cache_usd
      },
      %{
        attempted_model: attempted_model,
        trigger_reason: trigger_reason
      }
    )

    report =
      SpendReport.generate_and_save!(%{
        ledger: state,
        attempted_model: attempted_model,
        budget_limit_usd: limit,
        trigger_reason: trigger_reason
      })

    {report, %{state | last_report_path: report.report_path}}
  end
end
