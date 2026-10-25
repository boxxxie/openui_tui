defmodule Mix.Tasks.Openui.Status do
  @moduledoc """
  Displays the current OpenUI TUI Maker operational status:
  - SpendGuard ledger and remaining budget against the $1.00 cap
  - Memcached L2 persistent cache connection status
  - Version & experiment tags
  - Telemetry event counts and token consumption
  """
  use Mix.Task

  @shortdoc "Displays OpenUI TUI spend ledger, cache status, and version telemetry"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    status = OpenUITUI.system_status()
    ledger = status.spend_ledger

    IO.puts(
      "\n" <>
        IO.ANSI.bright() <>
        IO.ANSI.cyan() <> "═══ OpenUI TUI Operational Status ═══" <> IO.ANSI.reset()
    )

    IO.puts("• Memcached L2 (127.0.0.1:11211): #{format_memcached(status.memcached)}")
    IO.puts("• Telemetry Log: #{status.telemetry_jsonl_path}")

    IO.puts(
      "\n" <> IO.ANSI.bright() <> "── SpendGuard Ledger ($1.00 Hard Budget) ──" <> IO.ANSI.reset()
    )

    spend = ledger.billed_gemini_spend_usd
    limit = ledger.budget_limit_usd
    remaining = max(limit - spend, 0.0)
    utilization = spend / max(limit, 0.0001) * 100.0
    halted? = spend >= limit

    IO.puts("  Billed Spend:      $#{:erlang.float_to_binary(spend, decimals: 6)}")
    IO.puts("  Budget Cap:        $#{:erlang.float_to_binary(limit, decimals: 2)}")
    IO.puts("  Remaining:         $#{:erlang.float_to_binary(remaining, decimals: 6)}")
    IO.puts("  Utilization:       #{Float.round(utilization, 2)}%")

    IO.puts(
      "  Halted Overrun?:   #{if halted?, do: IO.ANSI.red() <> "YES" <> IO.ANSI.reset(), else: IO.ANSI.green() <> "NO (Active)" <> IO.ANSI.reset()}"
    )

    IO.puts("  Total Live Calls:  #{ledger.call_count}")

    IO.puts(
      "  Jev SystemOne:     #{ledger.jev_call_count} calls ($0.00 effective / close-to-free)"
    )

    IO.puts(
      "  Cache Savings:     $#{:erlang.float_to_binary(ledger.saved_by_cache_usd, decimals: 6)} (#{ledger.cache_hit_count} hits)"
    )

    IO.puts("\n" <> IO.ANSI.bright() <> "── Version & Experiment Tags ──" <> IO.ANSI.reset())

    Enum.each(status.version_tags, fn {k, v} ->
      IO.puts("  #{String.pad_trailing(to_string(k), 18)}: #{v}")
    end)

    version_summary = OpenUITUI.compare_versions()
    cohorts = Map.get(version_summary, :versions, %{})

    if map_size(cohorts) > 0 do
      IO.puts("\n" <> IO.ANSI.bright() <> "── Telemetry Cohort Summary ──" <> IO.ANSI.reset())

      Enum.each(cohorts, fn {cohort, data} ->
        IO.puts("  • #{cohort}")

        IO.puts(
          "      Calls: #{data.total_calls} | Cache Hit: #{Float.round(data.cache_hit_rate_pct, 1)}% | Avg Tokens: #{round(data.avg_tokens_per_call)} | Billed: $#{:erlang.float_to_binary(data.effective_spend_usd, decimals: 6)}"
        )
      end)
    end

    IO.puts("")
  end

  defp format_memcached({:ok, version}),
    do: IO.ANSI.green() <> "ONLINE (v#{version})" <> IO.ANSI.reset()

  defp format_memcached({:error, reason}),
    do: IO.ANSI.red() <> "OFFLINE (#{inspect(reason)})" <> IO.ANSI.reset()
end
