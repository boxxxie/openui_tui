defmodule Mix.Tasks.Openui.Live do
  @moduledoc """
  Runs a live 80-column Terminal telemetry session polling Memcached and BEAM
  at 1–10Hz using the two-loop architecture (0 ongoing LLM token cost).

  ## Examples

      mix openui.live
      mix openui.live --duration 5
      mix openui.live --interval 500
      mix openui.live --file priv/examples/live_memcached.oui
  """
  use Mix.Task

  alias OpenUITUI.LiveSession

  @shortdoc "Runs a live 80-column TUI dashboard with real-time BEAM & Memcached metrics"

  @default_openui """
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
  c_evict = Col("Evictions", 20, "right")
  div3 = Divider("Live Actions")
  ctrl_form = Form([f_slab], [btn_analyze])
  f_slab = Select("Target Slab", $slab_inspect, $live_slab_ids)
  btn_analyze = Button("Diagnose Slab")
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          duration: :integer,
          interval: :integer,
          file: :string
        ],
        aliases: [
          d: :duration,
          i: :interval,
          f: :file
        ]
      )

    duration_sec = Keyword.get(opts, :duration, 5)
    interval_ms = Keyword.get(opts, :interval, 1000)

    code =
      case Keyword.get(opts, :file) do
        nil -> @default_openui
        path -> File.read!(path)
      end

    {:ok, session} =
      LiveSession.start_link(
        auto_poll: false,
        write_tty: false,
        interval_ms: interval_ms
      )

    :ok = LiveSession.load_openui(session, code)

    IO.puts(IO.ANSI.clear() <> IO.ANSI.home())

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.cyan() <>
        "Starting live 80-column TUI (#{duration_sec}s demo, interval: #{interval_ms}ms)..." <>
        IO.ANSI.reset()
    )

    steps = if duration_sec > 0, do: max(round(duration_sec * 1000 / interval_ms), 1), else: 10

    for step <- 1..steps do
      LiveSession.poll_now(session)
      lines = LiveSession.render_lines(session, ansi?: true, tick: step)

      # Render at top of terminal
      IO.write([
        IO.ANSI.home(),
        Enum.join(lines, "\n"),
        "\n" <>
          IO.ANSI.faint() <>
          "  [Tick ##{step}/#{steps} | Polling 127.0.0.1:11211 & BEAM memory | Press Ctrl+C to exit]" <>
          IO.ANSI.reset() <> "\n"
      ])

      Process.sleep(interval_ms)
    end

    IO.puts(
      "\n" <> IO.ANSI.green() <> "✓ Completed live session demonstration." <> IO.ANSI.reset()
    )
  end
end
