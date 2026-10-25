defmodule Mix.Tasks.Openui.Cli do
  @shortdoc "Scriptable CLI test & iteration hooks for OpenUI Studio (prompt, keys, inspect, smoke, reset)"

  @moduledoc """
  Headless CLI hooks into `OpenUITUI.Studio` so you (or an agent) can iterate, reproduce bugs,
  inspect state, simulate raw keystrokes, and verify LLM prompt evolution without entering the
  interactive full-screen terminal loop.

  ## Subcommands

      # 1. Run full automated Studio smoke & invariant test suite (seed apps + keys + AST torture + live LLM)
      mix openui.cli smoke
      mix openui.cli smoke --no-llm

      # 2. Trace a conversational prompt end-to-end (sandbox by default; pass --persist to save to disk)
      mix openui.cli prompt "i want a ui for memcached"
      mix openui.cli prompt "add an alert for high evictions" --app memcached-live --tab split
      mix openui.cli prompt "build a redis cluster monitor" --persist

      # 3. Simulate a sequence of raw keystrokes & navigation actions
      mix openui.cli keys 'type:"i want a ui for memcached" enter tab'
      mix openui.cli keys 'tab space down enter ctrl+s' --app memcached-live

      # 4. Inspect a saved app's state, controls, symbols, and rendered frame
      mix openui.cli inspect --app postgres-triage --tab split
      mix openui.cli inspect --app memcached-live --json

      # 5. Reset priv/studio_apps/*.json cleanly back to the 3 default seed apps
      mix openui.cli reset
  """

  use Mix.Task

  alias OpenUITUI.Studio.{Harness, Store}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          app: :string,
          tab: :string,
          width: :integer,
          height: :integer,
          persist: :boolean,
          json: :boolean,
          llm: :boolean,
          bypass_cache: :boolean
        ],
        aliases: [a: :app, t: :tab, w: :width, h: :height, j: :json]
      )

    case positional do
      ["reset" | _] ->
        Store.reset_seed_apps!()

        IO.puts(
          "✔ Reset priv/studio_apps/*.json to clean starter apps (memcached-live, hetzner-fleet, postgres-triage)."
        )

      ["smoke" | _] ->
        run_smoke(opts)

      ["prompt", prompt_str | _] ->
        run_prompt_trace(prompt_str, opts)

      ["keys", dsl_str | _] ->
        run_keys_sim(dsl_str, opts)

      ["inspect" | _] ->
        run_inspect(opts)

      _ ->
        print_usage()
    end
  end

  defp run_smoke(opts) do
    live_llm? = Keyword.get(opts, :llm, true)
    res = Harness.run_smoke_suite(live_llm?: live_llm?)

    if opts[:json] do
      IO.puts(Jason.encode!(res, pretty: true))
    else
      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ OpenUI Studio CLI Smoke & Invariant Suite (#{res.passed}/#{res.total} passed) ═══" <>
          IO.ANSI.reset()
      )

      Enum.each(res.results, fn r ->
        if r.status == :passed do
          IO.puts("  #{IO.ANSI.green()}✔ PASS#{IO.ANSI.reset()} #{r.name} (#{r.duration_ms}ms)")
        else
          IO.puts("  #{IO.ANSI.red()}✖ FAIL#{IO.ANSI.reset()} #{r.name} (#{r.duration_ms}ms)")
          IO.puts("    Error: #{r.error}")
          IO.puts("    #{r.stacktrace}")
        end
      end)

      if res.failed > 0 do
        Mix.raise("OpenUI Studio smoke suite had #{res.failed} failure(s)")
      end
    end
  end

  defp run_prompt_trace(prompt_str, opts) do
    tab = parse_tab(Keyword.get(opts, :tab, "split"))
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)
    persist? = Keyword.get(opts, :persist, false)

    trace =
      Harness.trace_prompt(prompt_str,
        app_id: opts[:app],
        tab: tab,
        width: width,
        height: height,
        persist?: persist?,
        ansi?: not Keyword.get(opts, :json, false),
        bypass_cache: Keyword.get(opts, :bypass_cache, false)
      )

    if opts[:json] do
      IO.puts(Jason.encode!(Map.delete(trace, :send_result), pretty: true))
    else
      mode_lbl = if persist?, do: "PERSISTED to disk", else: "SANDBOX (non-destructive)"

      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ OpenUI Studio Prompt Trace [#{mode_lbl}] ═══" <>
          IO.ANSI.reset()
      )

      IO.puts("  • Prompt         : #{inspect(prompt_str)}")
      IO.puts("  • Status         : #{trace.status} (#{trace.elapsed_ms}ms)")

      IO.puts(
        "  • Stage Verified : #{trace.stage_verified?} (user bubble + ⟳ indicator staged before LLM call)"
      )

      IO.puts(
        "  • App Evolution  : #{trace.before.app_id} v#{trace.before.revision} (#{trace.before.title}) ➔ v#{trace.after.revision} (#{trace.after.title})"
      )

      IO.puts(
        "  • Has Valid Root : #{trace.after.has_root?} (symbols: #{Enum.join(trace.after.symbol_keys, ", ")})"
      )

      IO.puts("  • Eval Errors    : #{inspect(trace.after.eval_errors)}")

      IO.puts(
        "  • Controls (#{length(trace.after.controls)}) : #{inspect(Enum.map(trace.after.controls, &"#{&1.kind}:#{&1.label}"))}"
      )

      IO.puts(
        "  • All 5 Tabs & 5 Renderers Geometry Valid (#{width}x#{height}): #{trace.all_geometry_valid?}"
      )

      IO.puts("\n" <> IO.ANSI.faint() <> "─── Merged OpenUI Code ───" <> IO.ANSI.reset())
      IO.puts(trace.after.openui_code)

      IO.puts(
        "\n" <>
          IO.ANSI.faint() <>
          "─── Rendered Studio Frame (#{tab}, #{width}x#{height}) ───" <> IO.ANSI.reset()
      )

      IO.puts(trace.rendered_frame)
    end
  end

  defp run_keys_sim(dsl_str, opts) do
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)
    persist? = Keyword.get(opts, :persist, false)

    sim =
      Harness.simulate_keys(dsl_str,
        app_id: opts[:app],
        width: width,
        height: height,
        persist?: persist?,
        ansi?: not Keyword.get(opts, :json, false)
      )

    if opts[:json] do
      IO.puts(Jason.encode!(sim, pretty: true))
    else
      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ OpenUI Studio Keystroke Simulation (#{length(sim.steps)} steps) ═══" <>
          IO.ANSI.reset()
      )

      Enum.each(sim.steps, fn s ->
        IO.puts(
          "  [#{s.step}] token=#{inspect(s.token)} ➔ tab=#{s.active_tab} buf=#{inspect(s.input_buffer)} rev=v#{s.revision} focus=#{s.focused_control} state=#{inspect(s.ui_state)}"
        )
      end)

      IO.puts(
        "\n" <>
          IO.ANSI.faint() <>
          "─── Final Studio Frame (#{sim.final_tab}, #{width}x#{height}) ───" <> IO.ANSI.reset()
      )

      IO.puts(sim.rendered_frame)
    end
  end

  defp run_inspect(opts) do
    tab = parse_tab(Keyword.get(opts, :tab, "split"))
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)

    info =
      Harness.inspect_app(opts[:app],
        tab: tab,
        width: width,
        height: height,
        ansi?: not Keyword.get(opts, :json, false)
      )

    if opts[:json] do
      IO.puts(Jason.encode!(info, pretty: true))
    else
      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ OpenUI Studio App Inspection: #{info.app_id} (v#{info.revision}) ═══" <>
          IO.ANSI.reset()
      )

      IO.puts("  • Title      : #{info.title}")
      IO.puts("  • Renderer   : :#{info.renderer}")
      IO.puts("  • Revisions  : v#{info.revision} (#{info.history_count} undo snapshots)")
      IO.puts("  • Messages   : #{info.message_count}")
      IO.puts("  • UI State   : #{inspect(info.ui_state)}")

      IO.puts(
        "  • Controls   : #{inspect(Enum.map(info.controls, &"#{&1.kind}:#{&1.label}(#{Map.get(&1, :var, &1.id)})"))}"
      )

      IO.puts("  • Symbols    : #{Enum.join(info.symbol_keys, ", ")}")
      IO.puts("\n" <> info.rendered_frame)
    end
  end

  defp parse_tab("chat"), do: :chat
  defp parse_tab("app"), do: :app
  defp parse_tab("split"), do: :split
  defp parse_tab("code"), do: :code
  defp parse_tab("apps"), do: :apps
  defp parse_tab(_), do: :split

  defp print_usage do
    IO.puts("""
    Usage:
      mix openui.cli smoke [--no-llm] [--json]
      mix openui.cli prompt "<prompt>" [--app <id>] [--tab split|app|chat|code|apps] [--persist] [--json]
      mix openui.cli keys '<keystroke_dsl>' [--app <id>] [--persist] [--json]
      mix openui.cli inspect [--app <id>] [--tab split|app|chat|code|apps] [--json]
      mix openui.cli reset
    """)
  end
end
