defmodule OpenUITUI.Memcached.Probe do
  @moduledoc """
  Polls local `memcached` (`127.0.0.1:11211`) over ASCII TCP (`stats`, `stats slabs`,
  `stats items`), delegates parsing to `OpenUITUI.Memcached.Parser`, and computes
  real-time rate deltas and 18-point sliding window buffers mapped to OpenUI `$live_*`
  bindings.
  """

  alias OpenUITUI.Memcached.Parser

  @spark_window 18

  defstruct prev_stats: nil,
            prev_ts: nil,
            ops_history: List.duplicate(0, @spark_window),
            hit_history: List.duplicate(100.0, @spark_window)

  @type t :: %__MODULE__{}

  @doc """
  Fetches raw `stats`, `stats slabs`, and `stats items` over `:gen_tcp` and parses
  them via `OpenUITUI.Memcached.Parser`.
  """
  @spec fetch_raw(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_raw(host \\ "127.0.0.1", port \\ 11_211) do
    host_charlist = String.to_charlist(host)

    with {:ok, sock} <-
           :gen_tcp.connect(host_charlist, port, [:binary, active: false, packet: :line], 1_500),
         :ok <- :gen_tcp.send(sock, "stats\r\nstats slabs\r\nstats items\r\n"),
         {:ok, stats} <- recv_until_end(sock, 3, %{}) do
      :gen_tcp.close(sock)
      {:ok, stats}
    end
  end

  @doc """
  Fetches and returns a structured 5-section `%OpenUITUI.Memcached.Parser{}` report
  from a running Memcached instance.
  """
  @spec fetch_parsed(String.t(), pos_integer()) :: {:ok, Parser.t()} | {:error, term()}
  def fetch_parsed(host \\ "127.0.0.1", port \\ 11_211) do
    with {:ok, raw} <- fetch_raw(host, port) do
      {:ok, Parser.parse(raw)}
    end
  end

  @doc """
  Takes a single pre-flight introspection snapshot of `memcached` and returns a
  compact summary string for the LLM context alongside the initial `$live_*` bindings.
  """
  @spec introspect_summary(String.t(), pos_integer()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def introspect_summary(host \\ "127.0.0.1", port \\ 11_211) do
    with {:ok, raw} <- fetch_raw(host, port) do
      {_probe, bindings} = compute_live_bindings(%__MODULE__{}, raw)

      summary =
        "Memcached (#{host}:#{port}) pre-flight snapshot (parsed via OpenUITUI.Memcached.Parser): " <>
          "#{bindings["$live_diagnostic_summary"]}. " <>
          "Top populated slabs: #{Enum.join(bindings["$live_slab_ids"], ", ")}. " <>
          "Available $live bindings: $live_ops_kv, $live_service_kpi, $live_conns_kpi, " <>
          "$live_ops_sec, $live_ops_delta, $live_ops_history, $live_hit_ratio, " <>
          "$live_gets_sets, $live_hits_misses, $live_mem_short, $live_mem_used, " <>
          "$live_items_evict, $live_evict_rate, $live_hit_history, $live_slab_bars, " <>
          "$live_slab_rows, $live_slab_ids, $live_uptime_footer."

      {:ok, summary, bindings}
    end
  end

  defp recv_until_end(_sock, 0, acc), do: {:ok, acc}

  defp recv_until_end(sock, ends_remaining, acc) do
    case :gen_tcp.recv(sock, 0, 1_500) do
      {:ok, "END\r\n"} ->
        recv_until_end(sock, ends_remaining - 1, acc)

      {:ok, line} ->
        case Parser.parse_stat_line(line) do
          {:ok, key, val} ->
            recv_until_end(sock, ends_remaining, Map.put(acc, key, val))

          :ignore ->
            recv_until_end(sock, ends_remaining, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Transforms a raw memcached map (or ASCII string) + probe history into OpenUI `$live_*`
  symbol bindings via `OpenUITUI.Memcached.Parser`.
  """
  @spec compute_live_bindings(t(), map() | String.t()) :: {t(), map()}
  def compute_live_bindings(%__MODULE__{} = state, raw_input) do
    report = Parser.parse(raw_input)
    raw = report.raw

    now_ms = System.monotonic_time(:millisecond)
    dt_sec = if state.prev_ts, do: max((now_ms - state.prev_ts) / 1000.0, 0.1), else: 1.0
    prev = state.prev_stats || raw

    ops_now = report.cache.cmd_get + report.cache.cmd_set
    ops_prev = Map.get(prev, "cmd_get", 0) + Map.get(prev, "cmd_set", 0)
    ops_sec = round(max(ops_now - ops_prev, 0) / dt_sec)

    prev_ops_sec = List.last(state.ops_history) || 0
    ops_delta_diff = ops_sec - prev_ops_sec

    ops_delta_str =
      if ops_delta_diff >= 0, do: "+#{ops_delta_diff}/s", else: "#{ops_delta_diff}/s"

    evict_delta =
      round(max(report.memory.evictions - Map.get(prev, "evictions", 0), 0) / dt_sec)

    ops_hist = Enum.take(state.ops_history ++ [ops_sec], -@spark_window)
    hit_hist = Enum.take(state.hit_history ++ [report.cache.hit_ratio_pct], -@spark_window)

    bindings =
      Parser.to_openui_bindings(report,
        ops_sec: ops_sec,
        ops_delta_str: ops_delta_str,
        evict_delta: evict_delta,
        ops_history: ops_hist,
        hit_history: hit_hist
      )

    next_state = %{
      state
      | prev_stats: raw,
        prev_ts: now_ms,
        ops_history: ops_hist,
        hit_history: hit_hist
    }

    {next_state, bindings}
  end
end
