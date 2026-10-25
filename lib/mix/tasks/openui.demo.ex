defmodule Mix.Tasks.Openui.Demo do
  @moduledoc """
  Runs an end-to-end demonstration of `OpenUITUI`:
  1. Verifies `Memcached` (`127.0.0.1:11211`) and `LiteLLM` (`OpenUITUI.Config.litellm_url/0`) connectivity.
  2. Compares `v1-full-prompt` vs `v2-jev-compact` (with TypeSafe Jev routing) on `gemini-2.5-flash-lite`.
  3. Demonstrates L1 (`Cachex`) and L2 (`Memcached`) cache hits avoiding duplicate API spend.
  4. Renders the generated OpenUI Lang across all 5 Elixir TUI engines (`:fixed_80`, `:pure_ansi`, `:owl`, `:table_rex`, `:compact_ops`).
  5. Demonstrates the Live Memcached + BEAM Telemetry Data Plane (`StreamSource` + `Bind` + `Sparkline` + 1/8th fractional `BarList`).
  6. Generates a full Spend & Version Telemetry Review Report (`priv/reports/spend_review_*.md`).
  """
  use Mix.Task

  alias OpenUITUI.LiveSession

  @shortdoc "Runs the OpenUI TUI Maker comparison, live Memcached telemetry, and spend benchmark"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts(
      "\n" <>
        IO.ANSI.bright() <>
        IO.ANSI.cyan() <>
        "═══ OpenUI Elixir TUI Maker — Live Benchmark & 5-Renderer Comparison ═══" <>
        IO.ANSI.reset()
    )

    status = OpenUITUI.system_status()
    IO.puts("• Memcached L2 (127.0.0.1:11211): #{inspect(status.memcached)}")
    IO.puts("• Telemetry JSONL Log: #{status.telemetry_jsonl_path}")

    prompt =
      "Create an ops dashboard titled 'Hetzner Production Fleet' with subtitle 'Cluster hel1-prod' showing an Alert('success', 'All 9 nodes healthy'), a Row of 3 Stat cards (Nodes '9/9', PG18 'Active', LiteLLM '192ms'), a Progress('Disk Usage', 62), a Table with Col('Server', ['api-gateway-01', 'pg-primary-01', 'cache-node-01']) and Col('Status', ['OK', 'OK', 'OK']), and a Panel('Runbook Actions', ['Verify S3 backup', 'Check error traces'])."

    # 1. Cohort A: v1-full-prompt (verbose system prompt, no Jev pre-routing)
    OpenUITUI.set_version_tags(
      program_version: "0.1.0-baseline",
      prompt_version: "v1-full-prompt",
      experiment_tag: "verbose-prompt-no-jev"
    )

    IO.puts(
      "\n--- [1] Running Cohort A (0.1.0-baseline | v1-full-prompt | gemini-2.5-flash-lite) ---"
    )

    {:ok, res_v1} =
      OpenUITUI.generate_tui(prompt,
        model: "gemini-2.5-flash-lite",
        use_jev_router: false
      )

    IO.puts(
      "  Status: cache=#{res_v1.cache_status} | prompt_tokens=#{res_v1.prompt_tokens} | completion_tokens=#{res_v1.completion_tokens} | billed_usd=$#{:erlang.float_to_binary(res_v1.effective_cost_usd, decimals: 6)}"
    )

    # 2. Cohort B: v2-jev-compact (Jev SystemOne router + compact prompt)
    OpenUITUI.set_version_tags(
      program_version: "0.2.0-jev-routed",
      prompt_version: "v2-jev-compact",
      experiment_tag: "jev-compact-prompt"
    )

    IO.puts(
      "\n--- [2] Running Cohort B (0.2.0-jev-routed | v2-jev-compact | Jev + gemini-2.5-flash-lite) ---"
    )

    {:ok, res_v2} =
      OpenUITUI.generate_tui(prompt,
        model: "gemini-2.5-flash-lite",
        use_jev_router: true
      )

    IO.puts(
      "  Jev Routing: archetype=#{res_v2.jev_routing[:archetype]} | recommended_renderer=#{res_v2.recommended_renderer} | density=#{res_v2.jev_routing[:density]} (jev_eff_cost=$0.00)"
    )

    IO.puts(
      "  Gemini Call: cache=#{res_v2.cache_status} | prompt_tokens=#{res_v2.prompt_tokens} | completion_tokens=#{res_v2.completion_tokens} | billed_usd=$#{:erlang.float_to_binary(res_v2.effective_cost_usd, decimals: 6)}"
    )

    # 3. Duplicate call -> L1 Cachex hit, then clear L1 -> L2 Memcached hit
    IO.puts("\n--- [3] Testing L1 (Cachex) & L2 (Memcached) Deduplication ---")

    {:ok, res_l1} =
      OpenUITUI.generate_tui(prompt, model: "gemini-2.5-flash-lite", use_jev_router: true)

    IO.puts("  Repeat Call #1 (L1 Cachex): cache_status=#{res_l1.cache_status}")

    OpenUITUI.Cache.clear_l1()

    {:ok, res_l2} =
      OpenUITUI.generate_tui(prompt, model: "gemini-2.5-flash-lite", use_jev_router: true)

    IO.puts(
      "  Repeat Call #2 after L1 eviction (L2 Memcached): cache_status=#{res_l2.cache_status}"
    )

    # 4. Show Generated OpenUI Lang and all 5 Elixir TUI Renderers
    IO.puts(
      "\n--- [4] Generated OpenUI Lang DSL (#{res_v2.openui_bytes}B vs #{res_v2.equivalent_json_bytes}B JSON -> #{res_v2.compression_savings_pct}% smaller) ---"
    )

    IO.puts(res_v2.openui_code)

    for {renderer_id, r_info} <-
          Enum.sort_by(res_v2.renderers, fn {k, _} -> Atom.to_string(k) end) do
      IO.puts(
        "\n" <>
          IO.ANSI.yellow() <>
          "▶ Renderer: #{renderer_id} (#{r_info.duration_us}µs, #{r_info.output_bytes} bytes, #{r_info.line_count} lines)" <>
          IO.ANSI.reset()
      )

      IO.puts(r_info.output)
    end

    # 5. Live 80-Column Memcached + BEAM Telemetry Session (`StreamSource` + `Bind`)
    IO.puts(
      "\n--- [5] Live 80-Column Memcached + BEAM Telemetry Data Plane (StreamSource + Bind) ---"
    )

    live_openui = """
    root = Panel("Memcached & BEAM Live Telemetry (127.0.0.1:11211)", [src, s_beam, b_ram, b_procs, kpis, div1, mem_bars, div2, slabs_tbl, div3, ctrl_form], "info")
    src = StreamSource("memcached", "127.0.0.1:11211", 1000)
    s_beam = StreamSource("beam", "beam", "erlang:memory", "term", 1000)
    b_ram = Bind($beam_ram, "beam", "total_mb", "value", "BEAM: {val}MB")
    b_procs = Bind($beam_procs, "beam", "process_count", "value", "{val} procs")
    $slab_inspect = "1"
    kpis = Row([ops_stat, hit_stat])
    ops_stat = Stat("Throughput", $live_ops_sec, $live_ops_delta, ops_spark)
    ops_spark = Sparkline($live_ops_history, "info")
    hit_stat = Stat("Hit Ratio", $live_hit_ratio, $beam_ram, hit_spark)
    hit_spark = Sparkline($live_hit_history, "ok")
    div1 = Divider("Memory Saturation & Slab Usage")
    mem_bars = BarList($live_slab_bars)
    div2 = Divider("Active Slab Classes (Live)")
    slabs_tbl = Table([c_id, c_chunk, c_used, c_evict], $live_slab_rows, $live_uptime_footer)
    c_id = Col("Slab", 8, "left")
    c_chunk = Col("Chunk Size", 14, "right")
    c_used = Col("Allocated", 16, "right")
    c_evict = Col("Evictions", 16, "right")
    div3 = Divider("Live Actions")
    ctrl_form = Form([f_slab], [btn_analyze])
    f_slab = Select("Target Slab", $slab_inspect, $live_slab_ids)
    btn_analyze = Button("Diagnose Slab", Action([@ToAssistant("Analyze eviction pressure on slab " + $slab_inspect)]))
    """

    {:ok, session} = LiveSession.start_link()
    :ok = LiveSession.load_openui(session, live_openui)
    {:ok, live_lines} = LiveSession.poll_now(session)
    IO.puts(Enum.join(live_lines, "\n"))

    # 6. Generate Spend & Telemetry Review Report
    report = OpenUITUI.generate_spend_report!(%{trigger_reason: "demo_benchmark_review"})
    IO.puts("\n--- [6] Spend & Version Telemetry Review Report Saved ---")
    IO.puts("  Report file: #{report.report_path}")
    IO.puts("\n" <> OpenUITUI.render(report.openui_code, :owl))
  end
end
