defmodule OpenUITUI.Memcached.Parser do
  @moduledoc """
  Standalone, deterministic Elixir parser for Memcached ASCII `stats`, `stats slabs`,
  and `stats items` output.

  ## How it connects to the OpenUI Example App

  1. **Raw Collection (`OpenUITUI.Memcached.Probe.fetch_raw_text/2`)**:
     Sends `"stats\\r\\nstats slabs\\r\\nstats items\\r\\n"` to `127.0.0.1:11211` over TCP
     (no LLM involved).
  2. **Structured Parsing (`OpenUITUI.Memcached.Parser.parse/1`)**:
     Parses raw `STAT <key> <value>` lines into a structured 5-section report:
     - `:service` — PID, version, uptime, threads
     - `:cache` — hit ratio %, GETs, hits, misses, SETs, flushes
     - `:memory` — bytes used, max bytes, utilization %, current/total items, evictions, OOM
     - `:connections` — current/max/total connections, network bytes read/written
     - `:slabs` — per-slab item counts, chunk sizes, pages, fill %, and evictions (sorted by active items)
  3. **OpenUI `$live_*` Binding Projection (`to_openui_bindings/2`)**:
     Converts the parsed 5-section struct into the `$live_*` variables referenced by
     the OpenUI `memcached-live` AST (`$live_ops_kv`, `$live_slab_rows`, `$live_hit_ratio`, etc.).
  """

  defstruct [
    :service,
    :cache,
    :memory,
    :connections,
    :slabs,
    :slab_summary,
    :raw
  ]

  @type slab_entry :: %{
          id: String.t(),
          id_int: non_neg_integer(),
          chunk_bytes: non_neg_integer(),
          chunk_human: String.t(),
          pages: non_neg_integer(),
          used_chunks: non_neg_integer(),
          total_chunks: pos_integer(),
          items: non_neg_integer(),
          evictions: non_neg_integer(),
          oom: non_neg_integer(),
          fill_pct: float()
        }

  @type t :: %__MODULE__{
          service: map(),
          cache: map(),
          memory: map(),
          connections: map(),
          slabs: [slab_entry()],
          slab_summary: map(),
          raw: map()
        }

  @doc """
  Parses raw Memcached ASCII output (`STAT <key> <value>` lines) into a raw key/value map.

  ## Example

      iex> OpenUITUI.Memcached.Parser.parse_text("STAT pid 1426\\r\\nSTAT version 1.6.45\\r\\nEND\\r\\n")
      %{"pid" => 1426, "version" => "1.6.45"}
  """
  @spec parse_text(String.t()) :: map()
  def parse_text(raw_text) when is_binary(raw_text) do
    raw_text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_stat_line(line) do
        {:ok, key, val} -> Map.put(acc, key, val)
        :ignore -> acc
      end
    end)
  end

  @doc """
  Parses a single `STAT <key> <value>` line safely (using `:binary.copy/1` to avoid
  retaining references to large TCP receive buffers).
  """
  @spec parse_stat_line(String.t()) ::
          {:ok, String.t(), integer() | float() | String.t()} | :ignore
  def parse_stat_line("STAT " <> rest) do
    case String.split(String.trim_trailing(rest), " ", parts: 2) do
      [k, v] ->
        key = :binary.copy(k)
        val = parse_scalar(:binary.copy(v))
        {:ok, key, val}

      _ ->
        :ignore
    end
  end

  def parse_stat_line(_line), do: :ignore

  @doc """
  Parses either raw Memcached ASCII output (`String.t()`) or a raw stats `map()`
  into a structured 5-section `%OpenUITUI.Memcached.Parser{}` report.
  """
  @spec parse(String.t() | map()) :: t()
  def parse(raw_text) when is_binary(raw_text) do
    raw_text
    |> parse_text()
    |> parse()
  end

  def parse(raw) when is_map(raw) do
    # 1. Service & Uptime
    pid = Map.get(raw, "pid", 0)
    version = to_string(Map.get(raw, "version", "1.6"))
    uptime_seconds = Map.get(raw, "uptime", 0)
    threads = Map.get(raw, "threads", 4)
    uptime_human = format_uptime(uptime_seconds)

    service = %{
      status: if(pid > 0, do: "Active (PID #{pid})", else: "Unknown"),
      pid: pid,
      version: version,
      uptime_seconds: uptime_seconds,
      uptime_human: uptime_human,
      threads: threads
    }

    # 2. Cache Performance & Hit Rate
    cmd_get = Map.get(raw, "cmd_get", 0)
    cmd_set = Map.get(raw, "cmd_set", 0)
    cmd_flush = Map.get(raw, "cmd_flush", 0)
    get_hits = Map.get(raw, "get_hits", 0)
    get_misses = Map.get(raw, "get_misses", 0)

    hit_ratio_pct =
      if cmd_get > 0 do
        Float.round(get_hits / cmd_get * 100.0, 2)
      else
        100.0
      end

    cache = %{
      hit_ratio_pct: hit_ratio_pct,
      hit_ratio_str: "#{hit_ratio_pct}%",
      cmd_get: cmd_get,
      get_hits: get_hits,
      get_misses: get_misses,
      cmd_set: cmd_set,
      cmd_flush: cmd_flush
    }

    # 5. Slab Class Distribution (parsed before memory so OOM totals are included)
    {slabs, slab_summary} = parse_slabs(raw)

    # 3. Memory & Storage Health
    bytes_used = Map.get(raw, "bytes", 0)
    limit_maxbytes = max(Map.get(raw, "limit_maxbytes", 67_108_864), 1)
    utilization_pct = Float.round(bytes_used / limit_maxbytes * 100.0, 2)
    curr_items = Map.get(raw, "curr_items", 0)
    total_items = Map.get(raw, "total_items", 0)
    evictions = Map.get(raw, "evictions", 0)
    oom_total = slab_summary.oom_total + Map.get(raw, "listen_disabled_num", 0)

    memory = %{
      bytes_used: bytes_used,
      memory_used_human: format_bytes_precise(bytes_used),
      limit_maxbytes: limit_maxbytes,
      memory_limit_human: format_bytes(limit_maxbytes),
      memory_short_human:
        "#{Float.round(bytes_used / 1_048_576, 1)}/#{round(limit_maxbytes / 1_048_576)}MB",
      utilization_pct: utilization_pct,
      curr_items: curr_items,
      total_items: total_items,
      evictions: evictions,
      oom_total: oom_total
    }

    # 4. Connections & Network Traffic
    curr_connections = Map.get(raw, "curr_connections", 0)
    max_connections = Map.get(raw, "max_connections", 1024)
    total_connections = Map.get(raw, "total_connections", 0)
    bytes_read = Map.get(raw, "bytes_read", 0)
    bytes_written = Map.get(raw, "bytes_written", 0)

    connections = %{
      curr_connections: curr_connections,
      max_connections: max_connections,
      total_connections: total_connections,
      bytes_read: bytes_read,
      network_in_human: format_bytes_precise(bytes_read),
      bytes_written: bytes_written,
      network_out_human: format_bytes_precise(bytes_written)
    }

    %__MODULE__{
      service: service,
      cache: cache,
      memory: memory,
      connections: connections,
      slabs: slabs,
      slab_summary: slab_summary,
      raw: raw
    }
  end

  @doc """
  Extracts and sorts per-slab metrics from a raw Memcached stat map.
  Merges `stats slabs` (`<id>:chunk_size`, `<id>:total_pages`, `<id>:used_chunks`, `<id>:total_chunks`)
  with `stats items` (`items:<id>:number`, `items:<id>:evicted`, `items:<id>:outofmemory`)
  and sorts descending by active item count.
  """
  @spec parse_slabs(map()) :: {[slab_entry()], map()}
  def parse_slabs(raw) when is_map(raw) do
    all_slabs =
      raw
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        case String.split(key, ":", parts: 2) do
          [id, "chunk_size"] ->
            case Integer.parse(id) do
              {id_int, ""} ->
                chunk_bytes = Map.get(raw, "#{id}:chunk_size", 0)
                pages = Map.get(raw, "#{id}:total_pages", 0)
                used_chunks = Map.get(raw, "#{id}:used_chunks", 0)
                total_chunks = max(Map.get(raw, "#{id}:total_chunks", 1), 1)
                items = Map.get(raw, "items:#{id}:number", used_chunks)

                evictions =
                  Map.get(raw, "items:#{id}:evicted", Map.get(raw, "items:#{id}:evictions", 0))

                oom = Map.get(raw, "items:#{id}:outofmemory", 0)
                fill_pct = Float.round(used_chunks / total_chunks * 100.0, 1)

                [
                  %{
                    id: id,
                    id_int: id_int,
                    chunk_bytes: chunk_bytes,
                    chunk_human: format_chunk(chunk_bytes),
                    pages: pages,
                    used_chunks: used_chunks,
                    total_chunks: total_chunks,
                    items: items,
                    evictions: evictions,
                    oom: oom,
                    fill_pct: fill_pct
                  }
                ]

              _ ->
                []
            end

          _ ->
            []
        end
      end)
      |> Enum.sort_by(
        fn s -> {s.items, s.used_chunks, s.evictions, s.pages, -s.id_int} end,
        :desc
      )

    top_slabs = Enum.take(all_slabs, 5)
    rest_slabs = Enum.drop(all_slabs, 5)

    summary = %{
      top_slabs: top_slabs,
      rest_slabs_count: length(rest_slabs),
      rest_items: Enum.sum(Enum.map(rest_slabs, & &1.items)),
      rest_pages: Enum.sum(Enum.map(rest_slabs, & &1.pages)),
      rest_evictions: Enum.sum(Enum.map(rest_slabs, & &1.evictions)),
      active_slabs: length(all_slabs),
      total_pages: Enum.sum(Enum.map(all_slabs, & &1.pages)),
      oom_total: Enum.sum(Enum.map(all_slabs, & &1.oom))
    }

    {all_slabs, summary}
  end

  @doc """
  Projects a parsed `%OpenUITUI.Memcached.Parser{}` report (plus optional rate deltas
  and sparkline history from `OpenUITUI.Memcached.Probe`) into the `$live_*` bindings
  consumed by the OpenUI `memcached-live` dashboard.
  """
  @spec to_openui_bindings(t(), keyword()) :: map()
  def to_openui_bindings(%__MODULE__{} = report, opts \\ []) do
    ops_sec = Keyword.get(opts, :ops_sec, 0)
    ops_delta_str = Keyword.get(opts, :ops_delta_str, "+0/s")
    evict_delta = Keyword.get(opts, :evict_delta, 0)
    ops_hist = Keyword.get(opts, :ops_history, List.duplicate(0, 18))
    hit_hist = Keyword.get(opts, :hit_history, List.duplicate(report.cache.hit_ratio_pct, 18))

    s = report.service
    c = report.cache
    m = report.memory
    conn = report.connections
    sm = report.slab_summary

    top_rows =
      Enum.map(sm.top_slabs, fn slab ->
        [
          "Slab ##{slab.id} (#{slab.chunk_human})",
          "#{format_int(slab.items)} items",
          "#{slab.pages}p (#{slab.pages}.0 MB)",
          "#{slab.fill_pct}% (#{slab.used_chunks}/#{slab.total_chunks}) #{format_number(slab.evictions)}ev"
        ]
      end)

    slab_rows =
      if sm.rest_slabs_count > 0 do
        other_row = [
          "Other (#{sm.rest_slabs_count} slabs)",
          "#{format_int(sm.rest_items)} items",
          "#{sm.rest_pages}p (#{sm.rest_pages}.0 MB)",
          "Remaining slabs • #{format_number(sm.rest_evictions)}ev"
        ]

        top_rows ++ [other_row]
      else
        top_rows
      end

    global_bar =
      {"BarItem",
       [
         "Total RAM (#{m.memory_limit_human})",
         m.utilization_pct,
         "#{m.memory_used_human}/#{m.memory_limit_human} (#{m.utilization_pct}%)"
       ]}

    slab_bars =
      sm.top_slabs
      |> Enum.take(4)
      |> Enum.map(fn slab ->
        {"BarItem",
         [
           "Slab ##{slab.id} (#{slab.chunk_human})",
           slab.fill_pct,
           "#{format_int(slab.items)} items (#{slab.pages}p • #{slab.fill_pct}%)"
         ]}
      end)

    slab_ids =
      case Enum.map(sm.top_slabs, & &1.id) do
        [] -> ["1"]
        ids -> ids
      end

    service_cache_kv = [
      [
        "Service",
        "PID #{s.pid} • v#{s.version} (#{s.threads}t)"
      ],
      [
        "Uptime",
        "#{s.uptime_human} (#{format_int(s.uptime_seconds)}s)"
      ],
      [
        "Hit Ratio",
        "#{c.hit_ratio_pct}% (#{format_number(c.get_hits)}/#{format_number(c.get_misses)})"
      ],
      [
        "Requests",
        "#{format_number(c.cmd_get)} GET • #{format_number(c.cmd_set)} SET (#{ops_sec}/s)"
      ]
    ]

    memory_net_kv = [
      [
        "RAM Used",
        "#{m.memory_used_human} / #{m.memory_limit_human} (#{m.utilization_pct}%)"
      ],
      [
        "Items",
        "#{format_int(m.curr_items)} active (#{format_number(m.total_items)} tot)"
      ],
      [
        "Evict/OOM",
        "#{format_int(m.evictions)} ev (#{evict_delta}/s) • #{m.oom_total} OOM"
      ],
      [
        "Net & Conns",
        "#{conn.curr_connections}/#{conn.max_connections} • #{format_bytes(conn.bytes_read)}/#{format_bytes(conn.bytes_written)}"
      ]
    ]

    ops_kv = [
      [
        "Service & Uptime",
        "PID #{s.pid} • v#{s.version} • Up #{s.uptime_human} (#{format_int(s.uptime_seconds)}s) • #{s.threads} threads"
      ],
      [
        "Cache Hit Ratio",
        "#{c.hit_ratio_pct}% (#{format_int(c.get_hits)} hits / #{format_int(c.get_misses)} misses)"
      ],
      [
        "Command Traffic",
        "#{format_int(c.cmd_get)} GET • #{format_int(c.cmd_set)} SET • #{format_int(c.cmd_flush)} flushes • Live #{ops_sec}/s (#{ops_delta_str})"
      ],
      [
        "Memory & Items",
        "#{m.memory_used_human} / #{m.memory_limit_human} (#{m.utilization_pct}%) • #{format_int(m.curr_items)} active / #{format_int(m.total_items)} stored"
      ],
      [
        "Evictions & OOM",
        "#{format_int(m.evictions)} evictions (#{evict_delta}/s) • #{m.oom_total} OOM • #{sm.active_slabs} active slabs"
      ],
      [
        "Network & Conns",
        "#{conn.curr_connections}/#{format_int(conn.max_connections)} conns (#{format_int(conn.total_connections)} total) • In #{conn.network_in_human} • Out #{conn.network_out_human}"
      ]
    ]

    top_slabs_summary =
      Enum.map_join(sm.top_slabs, "; ", fn slab ->
        "Slab ##{slab.id} (#{slab.chunk_human}, #{slab.chunk_bytes}B): #{slab.items} items, #{slab.pages}p, #{slab.fill_pct}% fill (#{slab.used_chunks}/#{slab.total_chunks}), #{slab.evictions} evictions"
      end)

    %{
      "$live_service_cache_kv" => service_cache_kv,
      "$live_memory_net_kv" => memory_net_kv,
      "$live_ops_kv" => ops_kv,
      "$live_service_kpi" => "v#{s.version}",
      "$live_conns_kpi" => "PID #{s.pid}",
      "$live_ops_sec" => "#{format_number(ops_sec)}/s",
      "$live_ops_delta" => ops_delta_str,
      "$live_ops_history" => ops_hist,
      "$live_hit_ratio" => c.hit_ratio_str,
      "$live_gets_sets" => "#{format_number(c.cmd_get)} GET",
      "$live_hits_misses" =>
        "#{format_int(c.get_hits)} hits / #{format_int(c.get_misses)} misses",
      "$live_evict_rate" => "#{evict_delta} ev/s (#{format_int(m.evictions)} tot)",
      "$live_hit_history" => hit_hist,
      "$live_mem_short" => m.memory_short_human,
      "$live_mem_used" =>
        "#{m.memory_used_human} / #{m.memory_limit_human} (#{m.utilization_pct}%)",
      "$live_mem_pct" => m.utilization_pct,
      "$live_items_evict" => "#{format_int(m.curr_items)} itm",
      "$live_connections" =>
        "#{conn.curr_connections} / #{format_int(conn.max_connections)} (#{format_int(conn.total_connections)} total)",
      "$live_net_io" => "In #{conn.network_in_human} │ Out #{conn.network_out_human}",
      "$live_items" => "#{format_int(m.curr_items)} (#{format_int(m.total_items)} stored)",
      "$live_uptime" => "#{s.uptime_human} (#{format_int(s.uptime_seconds)}s)",
      "$live_slab_bars" => [global_bar | slab_bars],
      "$live_slab_rows" => slab_rows,
      "$live_slab_ids" => slab_ids,
      "$live_uptime_footer" =>
        "Total: #{format_int(m.curr_items)} items across #{sm.active_slabs} slabs (#{sm.total_pages}p / #{sm.total_pages}.0 MB pool) • Net Out #{conn.network_out_human}",
      "$live_diagnostic_summary" =>
        "v#{s.version} PID=#{s.pid}, uptime=#{s.uptime_human}, hit_ratio=#{c.hit_ratio_pct}% (#{format_int(c.get_hits)} hits / #{format_int(c.get_misses)} misses), mem=#{m.memory_used_human}/#{m.memory_limit_human} (#{m.utilization_pct}%), items=#{format_int(m.curr_items)}, evictions=#{format_int(m.evictions)}, OOM=#{m.oom_total}. Slabs: [#{top_slabs_summary}]"
    }
  end

  defp parse_scalar(str) do
    case Integer.parse(str) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(str) do
          {flt, ""} -> flt
          _ -> str
        end
    end
  end

  @doc false
  def format_chunk(n) when is_integer(n) and n >= 1_048_576,
    do: "#{Float.round(n / 1_048_576, 1)}MB"

  def format_chunk(n) when is_integer(n) and n >= 1024,
    do: "#{Float.round(n / 1024, 1)}KB"

  def format_chunk(n), do: "#{n}B"

  @doc false
  def format_bytes_precise(n) when is_integer(n) and n >= 1_073_741_824,
    do: "#{Float.round(n / 1_073_741_824, 2)} GB"

  def format_bytes_precise(n) when is_integer(n) and n >= 1_048_576,
    do: "#{Float.round(n / 1_048_576, 2)} MB"

  def format_bytes_precise(n) when is_integer(n) and n >= 1024,
    do: "#{Float.round(n / 1024, 1)} KB"

  def format_bytes_precise(n), do: "#{n} B"

  @doc false
  def format_bytes(n) when is_integer(n) and n >= 1_073_741_824,
    do: "#{Float.round(n / 1_073_741_824, 1)} GB"

  def format_bytes(n) when is_integer(n) and n >= 1_048_576,
    do: "#{Float.round(n / 1_048_576, 1)} MB"

  def format_bytes(n) when is_integer(n) and n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def format_bytes(n), do: "#{n} B"

  @doc false
  def format_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 2)}M"

  def format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_number(n), do: to_string(n)

  @doc false
  def format_int(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_int(n), do: to_string(n)

  @doc false
  def format_uptime(seconds) when is_integer(seconds) and seconds >= 86_400 do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    "~#{days}d #{hours}h"
  end

  def format_uptime(seconds) when is_integer(seconds) and seconds >= 3_600 do
    hours = div(seconds, 3_600)
    mins = div(rem(seconds, 3_600), 60)
    "~#{hours}h #{mins}m"
  end

  def format_uptime(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  def format_uptime(other), do: to_string(other)
end
