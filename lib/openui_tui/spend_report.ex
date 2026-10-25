defmodule OpenUITUI.SpendReport do
  @moduledoc """
  Generates structured post-mortem / spend review reports whenever the `$1.00`
  spend limit is reached or when requested on demand for human & agent review.

  Produces:
  1. A comprehensive Markdown report saved to `priv/reports/spend_review_<timestamp>.md`.
  2. Version-by-version telemetry correlation (`program_version`, `prompt_version`, `experiment_tag`).
  3. Anomaly & inefficiency findings (duplicate uncached calls, prompt bloat, model selection).
  4. An OpenUI Lang program (`report.openui_code`) so the spend review can also be rendered
     directly as a TUI dashboard!
  """

  alias OpenUITUI.{Config, Telemetry}

  @doc """
  Analyzes the JSONL telemetry log and active `SpendGuard` ledger, writes a Markdown
  review report to disk, and returns the report map.
  """
  @spec generate_and_save!(map()) :: map()
  def generate_and_save!(opts \\ %{}) do
    jsonl_path = Map.get(opts, :jsonl_path, Config.telemetry_jsonl_path())
    events = Telemetry.read_jsonl(jsonl_path)
    version_comparison = Telemetry.compare_versions(jsonl_path)

    api_events =
      Enum.filter(events, fn e ->
        e["event"] in ["openui_tui.llm.call", "openui_tui.jev.call"]
      end)

    live_calls =
      Enum.filter(api_events, fn e ->
        e["cache_status"] not in ["hit_l1_cachex", "hit_l2_memcached"]
      end)

    cached_calls =
      Enum.filter(api_events, fn e ->
        e["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"]
      end)

    billed_gemini_spend =
      Enum.reduce(live_calls, 0.0, fn e, acc -> acc + (e["effective_cost_usd"] || 0.0) end)

    jev_raw_spend =
      Enum.reduce(live_calls, 0.0, fn e, acc ->
        if e["event"] == "openui_tui.jev.call" or Config.jev_model?(e["model"] || "") do
          acc + (e["raw_cost_usd"] || 0.0)
        else
          acc
        end
      end)

    saved_by_cache =
      Enum.reduce(cached_calls, 0.0, fn e, acc -> acc + (e["saved_cost_usd"] || 0.0) end)

    saved_raw_by_cache =
      Enum.reduce(cached_calls, 0.0, fn e, acc -> acc + (e["saved_raw_cost_usd"] || 0.0) end)

    budget_limit =
      Map.get(opts, :budget_limit_usd) ||
        get_in(opts, [:ledger, :budget_limit_usd]) ||
        Config.budget_limit_usd()

    # Use ledger spend if higher than JSONL (e.g. during in-memory test simulation)
    ledger_billed = get_in(opts, [:ledger, :billed_gemini_spend_usd]) || 0.0
    effective_billed = max(billed_gemini_spend, ledger_billed)

    by_model = summarize_by_model(api_events)

    top_expensive_calls =
      live_calls
      |> Enum.sort_by(fn e -> -(e["raw_cost_usd"] || 0.0) end)
      |> Enum.take(5)

    findings =
      derive_findings(api_events, by_model, version_comparison, effective_billed, budget_limit)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    reports_dir = Config.reports_dir()
    :ok = File.mkdir_p(reports_dir)
    report_path = Path.join(reports_dir, "spend_review_#{timestamp}.md")

    summary = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      trigger_reason: Map.get(opts, :trigger_reason, "manual_review"),
      attempted_model: Map.get(opts, :attempted_model, "n/a"),
      budget_limit_usd: budget_limit,
      billed_gemini_spend_usd: Float.round(effective_billed, 6),
      jev_raw_spend_usd: Float.round(jev_raw_spend, 6),
      saved_by_cache_usd: Float.round(saved_by_cache, 6),
      saved_raw_by_cache_usd: Float.round(saved_raw_by_cache, 6),
      total_api_requests: length(api_events),
      live_network_calls: length(live_calls),
      cached_calls: length(cached_calls),
      cache_hit_rate_pct:
        if(api_events != [],
          do: Float.round(length(cached_calls) / length(api_events) * 100.0, 1),
          else: 0.0
        ),
      by_model: by_model,
      by_version: version_comparison.versions,
      top_expensive_calls: top_expensive_calls,
      findings: findings,
      report_path: report_path
    }

    markdown = render_markdown(summary)
    :ok = File.write(report_path, markdown)

    openui_code = render_openui_dashboard(summary)

    summary
    |> Map.put(:markdown, markdown)
    |> Map.put(:openui_code, openui_code)
  end

  defp summarize_by_model(api_events) do
    api_events
    |> Enum.group_by(&(&1["model"] || "unknown"))
    |> Map.new(fn {model, evs} ->
      live = Enum.reject(evs, &(&1["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"]))
      cached = Enum.filter(evs, &(&1["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"]))

      prompt_tok = Enum.reduce(evs, 0, &(&2 + (&1["prompt_tokens"] || 0)))
      comp_tok = Enum.reduce(evs, 0, &(&2 + (&1["completion_tokens"] || 0)))
      eff_usd = Enum.reduce(live, 0.0, &(&2 + (&1["effective_cost_usd"] || 0.0)))
      raw_usd = Enum.reduce(live, 0.0, &(&2 + (&1["raw_cost_usd"] || 0.0)))

      {model,
       %{
         total_calls: length(evs),
         live_calls: length(live),
         cached_calls: length(cached),
         prompt_tokens: prompt_tok,
         completion_tokens: comp_tok,
         effective_spend_usd: Float.round(eff_usd, 6),
         raw_spend_usd: Float.round(raw_usd, 6),
         jev_exempt: Config.jev_model?(model)
       }}
    end)
  end

  defp derive_findings(api_events, by_model, version_comparison, effective_billed, budget_limit) do
    findings = []

    findings =
      if effective_billed >= budget_limit do
        [
          "BUDGET LIMIT REACHED: Effective Gemini spend ($#{:erlang.float_to_binary(effective_billed, decimals: 6)}) reached or exceeded the configured limit ($#{:erlang.float_to_binary(budget_limit, decimals: 4)}). Uncached LLM calls are paused pending human review."
          | findings
        ]
      else
        [
          "UNDER BUDGET: Effective Gemini spend ($#{:erlang.float_to_binary(effective_billed, decimals: 6)}) is within the $#{:erlang.float_to_binary(budget_limit, decimals: 2)} budget cap."
          | findings
        ]
      end

    total = length(api_events)

    cached =
      Enum.count(api_events, &(&1["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"]))

    findings =
      cond do
        total > 2 and cached == 0 ->
          [
            "ZERO CACHE HITS: #{total} API calls executed with 0% cache hit rate. Ensure identical prompts use normalized parameters and deterministic temperature (0.0) so Cachex/Memcached can deduplicate requests."
            | findings
          ]

        total > 0 ->
          rate = Float.round(cached / total * 100.0, 1)

          [
            "CACHE EFFICIENCY: #{cached}/#{total} requests (#{rate}%) were served from Cachex (L1) or Memcached (L2) at $0.00 cost."
            | findings
          ]

        true ->
          findings
      end

    # Check if version changes improved token consumption
    version_entries = Map.to_list(version_comparison.versions)

    findings =
      if length(version_entries) >= 2 do
        sorted = Enum.sort_by(version_entries, fn {_k, v} -> v.avg_tokens_per_call end)
        {best_ver, best_stats} = List.first(sorted)
        {worst_ver, worst_stats} = List.last(sorted)

        [
          "VERSION CORRELATION: Best token efficiency observed in `#{best_ver}` (#{best_stats.avg_tokens_per_call} avg tokens/call, $#{:erlang.float_to_binary(best_stats.effective_spend_usd, decimals: 6)} effective spend) vs `#{worst_ver}` (#{worst_stats.avg_tokens_per_call} avg tokens/call)."
          | findings
        ]
      else
        findings
      end

    # Check if any non-lite model was used
    non_lite =
      by_model
      |> Map.keys()
      |> Enum.reject(fn m ->
        String.contains?(m, "flash-lite") or Config.jev_model?(m)
      end)

    findings =
      if non_lite != [] do
        [
          "MODEL SELECTION WARNING: Higher-cost models detected (#{Enum.join(non_lite, ", ")}). Switch default generation to `gemini-2.5-flash-lite` or `gemini-3.5-flash-lite` and route classification/layout decisions through `typesafe/jev-latest`."
          | findings
        ]
      else
        [
          "MODEL DISCIPLINE: Only low-cost `flash-lite` and close-to-free `typesafe/jev` models were used."
          | findings
        ]
      end

    Enum.reverse(findings)
  end

  defp render_markdown(s) do
    model_rows =
      s.by_model
      |> Enum.sort_by(fn {m, _} -> m end)
      |> Enum.map_join("\n", fn {model, m} ->
        exempt = if m.jev_exempt, do: "Yes (Close to Free)", else: "No (Billed)"

        "| `#{model}` | #{m.total_calls} | #{m.live_calls} | #{m.cached_calls} | #{m.prompt_tokens} | #{m.completion_tokens} | $#{:erlang.float_to_binary(m.effective_spend_usd, decimals: 6)} | $#{:erlang.float_to_binary(m.raw_spend_usd, decimals: 6)} | #{exempt} |"
      end)

    version_rows =
      s.by_version
      |> Enum.sort_by(fn {v, _} -> v end)
      |> Enum.map_join("\n", fn {ver, v} ->
        "| `#{ver}` | #{v.total_calls} | #{v.cache_hit_rate_pct}% | #{v.avg_tokens_per_call} | #{v.avg_duration_ms}ms | $#{:erlang.float_to_binary(v.effective_spend_usd, decimals: 6)} | $#{:erlang.float_to_binary(v.saved_by_cache_usd, decimals: 6)} |"
      end)

    expensive_rows =
      s.top_expensive_calls
      |> Enum.map_join("\n", fn e ->
        "| `#{e["event_id"]}` | `#{e["model"]}` | `#{e["program_version"]}` / `#{e["prompt_version"]}` | #{e["prompt_tokens"] || 0} | #{e["completion_tokens"] || 0} | $#{:erlang.float_to_binary((e["raw_cost_usd"] || 0.0) * 1.0, decimals: 6)} | `#{e["prompt_hash"] || "n/a"}` |"
      end)

    findings_list = Enum.map_join(s.findings, "\n", fn f -> "- #{f}" end)

    """
    # OpenUI TUI Maker — LLM Spend & Telemetry Review Report

    - **Generated At**: `#{s.generated_at}`
    - **Trigger Reason**: `#{s.trigger_reason}`
    - **Attempted Model**: `#{s.attempted_model}`
    - **Budget Limit**: `$#{:erlang.float_to_binary(s.budget_limit_usd, decimals: 4)}`
    - **Effective Billed Spend (Gemini)**: `$#{:erlang.float_to_binary(s.billed_gemini_spend_usd, decimals: 6)}`
    - **TypeSafe Jev Raw Spend (Exempt / Close-to-Free)**: `$#{:erlang.float_to_binary(s.jev_raw_spend_usd, decimals: 6)}`
    - **Saved by Cachex + Memcached**: `$#{:erlang.float_to_binary(s.saved_by_cache_usd, decimals: 6)}` (Raw: `$#{:erlang.float_to_binary(s.saved_raw_by_cache_usd, decimals: 6)}`)
    - **Total Requests**: `#{s.total_api_requests}` (`#{s.live_network_calls}` live, `#{s.cached_calls}` cached — `#{s.cache_hit_rate_pct}%` hit rate)

    ---

    ## 1. Key Findings & Actionable Learnings

    #{findings_list}

    ---

    ## 2. Spend Breakdown by Model

    | Model | Total Calls | Live Calls | Cached Calls | Prompt Tokens | Completion Tokens | Effective Spend (USD) | Raw Proxy Cost (USD) | Jev Exempt? |
    | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
    #{if model_rows == "", do: "| _none_ | 0 | 0 | 0 | 0 | 0 | $0.000000 | $0.000000 | - |", else: model_rows}

    ---

    ## 3. Version & Prompt Correlation (`program_version | prompt_version | experiment_tag`)

    | Version Cohort | Calls | Cache Hit % | Avg Tokens/Call | Avg Latency | Effective Spend (USD) | Saved by Cache (USD) |
    | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{if version_rows == "", do: "| _none_ | 0 | 0.0% | 0.0 | 0.0ms | $0.000000 | $0.000000 |", else: version_rows}

    ---

    ## 4. Top Expensive Live API Calls

    | Event ID | Model | Version (`program / prompt`) | Prompt Tokens | Completion Tokens | Raw Cost (USD) | Prompt Hash |
    | :--- | :--- | :--- | ---: | ---: | ---: | :--- |
    #{if expensive_rows == "", do: "| _none_ | - | - | 0 | 0 | $0.000000 | - |", else: expensive_rows}
    """
  end

  defp render_openui_dashboard(s) do
    models = Map.keys(s.by_model) |> Enum.sort()
    calls = Enum.map(models, fn m -> s.by_model[m].total_calls end)
    cached = Enum.map(models, fn m -> s.by_model[m].cached_calls end)

    eff_spend =
      Enum.map(models, fn m ->
        "$" <> :erlang.float_to_binary(s.by_model[m].effective_spend_usd, decimals: 6)
      end)

    pct_used =
      if s.budget_limit_usd > 0 do
        min(100, Float.round(s.billed_gemini_spend_usd / s.budget_limit_usd * 100.0, 1))
      else
        100.0
      end

    status_tone = if s.billed_gemini_spend_usd >= s.budget_limit_usd, do: "error", else: "success"

    """
    root = Dashboard("OpenUI TUI Spend & Telemetry Review", "#{s.trigger_reason}", [alert_banner, kpi_row, budget_meter, model_table, findings_panel])
    alert_banner = Alert("#{status_tone}", "Effective Spend: $#{:erlang.float_to_binary(s.billed_gemini_spend_usd, decimals: 6)} / $#{:erlang.float_to_binary(s.budget_limit_usd, decimals: 4)} limit | Cache Hit Rate: #{s.cache_hit_rate_pct}%")
    kpi_row = Row([Stat("Billed Spend", "$#{:erlang.float_to_binary(s.billed_gemini_spend_usd, decimals: 6)}", "#{s.live_network_calls} live calls"), Stat("Jev Spend (Free)", "$#{:erlang.float_to_binary(s.jev_raw_spend_usd, decimals: 6)}", "SystemOne Router"), Stat("Cache Saved", "$#{:erlang.float_to_binary(s.saved_raw_by_cache_usd, decimals: 6)}", "#{s.cached_calls} hits (#{s.cache_hit_rate_pct}%)")])
    budget_meter = Progress("Budget Utilization ($1.00 Cap)", #{pct_used})
    model_table = Table([Col("Model", #{Jason.encode!(models)}), Col("Total Calls", #{Jason.encode!(calls)}), Col("Cache Hits", #{Jason.encode!(cached)}), Col("Billed USD", #{Jason.encode!(eff_spend)})])
    findings_panel = Panel("Key Learnings & Recommendations", #{Jason.encode!(s.findings)})
    """
  end
end
