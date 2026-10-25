defmodule OpenUITUI.Studio.Store do
  @moduledoc """
  Persistent disk storage for OpenUI Studio Conversations/Apps.

  In OpenUI Studio, every chat conversation IS a stateful OpenUI application:
  - `id`: unique slug (`"memcached-live"`, `"hetzner-fleet"`, `"app-..."`)
  - `title`: human-readable application title
  - `renderer`: active renderer atom name (`"fixed_80"`, `"owl"`, `"pure_ansi"`, `"table_rex"`, `"compact_ops"`)
  - `openui_code`: current OpenUI Lang source code (`root = ...`)
  - `ui_state`: map of interactive `$var` bindings (`%{"$slab_inspect" => "1"}`)
  - `revision`: integer revision counter (`1`, `2`, ...)
  - `history`: list of previous `%{revision, openui_code, summary}` snapshots for `/undo`
  - `messages`: ordered list of chat/action turns (`%{role, text, timestamp, meta}`)
  """

  @starter_apps [
    %{
      "id" => "memcached-live",
      "title" => "Memcached & BEAM Live Telemetry",
      "renderer" => "fixed_80",
      "revision" => 1,
      "created_at" => "2026-10-24T19:00:00Z",
      "updated_at" => "2026-10-24T19:00:00Z",
      "ui_state" => %{"$slab_inspect" => "1"},
      "history" => [],
      "openui_code" => """
      root = Dashboard("Memcached & BEAM Live Telemetry", "127.0.0.1:11211", [src, s_beam, b_ram, b_procs, kpis, ops_row, p_slabs, ctrl_form])
      src = StreamSource("memcached", "127.0.0.1:11211", 1000)
      s_beam = StreamSource("beam", "beam", "erlang:memory", "term", 1000)
      b_ram = Bind($beam_ram, "beam", "total_mb", "value", "BEAM: {val}MB")
      b_procs = Bind($beam_procs, "beam", "process_count", "value", "{val} procs")
      $slab_inspect = "1"
      kpis = Row([svc_stat, hit_stat, mem_stat])
      svc_stat = Stat("1. Service & Conns", $live_service_kpi, $live_conns_kpi, ops_spark)
      ops_spark = Sparkline($live_ops_history, "info")
      hit_stat = Stat("2. Hit Rate & Ops", $live_hit_ratio, $live_gets_sets, hit_spark)
      hit_spark = Sparkline($live_hit_history, "ok")
      mem_stat = Stat("3. Memory & Items", $live_mem_short, $live_items_evict)
      ops_row = Row([p_svc, p_mem])
      p_svc = Panel("1-2. Service & Cache Performance", [svc_kv], "info")
      svc_kv = KV($live_service_cache_kv)
      p_mem = Panel("3-4. Memory Health & Network I/O", [mem_kv], "ok")
      mem_kv = KV($live_memory_net_kv)
      p_slabs = Panel("5. Slab Class Distribution (Top Populated Slabs by Item Count)", [slabs_tbl], "info")
      slabs_tbl = Table([c_id, c_items, c_pages, c_util], $live_slab_rows, $live_uptime_footer)
      c_id = Col("Slab (Chunk)", 16, "left")
      c_items = Col("Items", 13, "right")
      c_pages = Col("Pages / Pool", 14, "right")
      c_util = Col("Util % / Evict", 22, "right")
      ctrl_form = Form([f_slab], [btn_analyze])
      f_slab = Select("Target Slab", $slab_inspect, $live_slab_ids)
      btn_analyze = Button("Diagnose Slab", @ToAssistant("Analyze eviction pressure and chunk sizing for slab class " + $slab_inspect))
      """,
      "messages" => [
        %{
          "role" => "user",
          "text" =>
            "Build a complete 5-section live Memcached & BEAM telemetry dashboard covering Service & Uptime, Cache Performance & Hit Rate, Memory & Storage Health, Connections & Traffic, and Slab Class Distribution.",
          "timestamp" => "19:00:01"
        },
        %{
          "role" => "assistant",
          "text" =>
            "Created the 5-section Memcached & BEAM Live Telemetry app polling `127.0.0.1:11211` (`stats`, `stats slabs`, `stats items`) and `erlang:memory` at 1Hz with KPI sparklines, full operational KV breakdown, top populated slabs table + summary row, and interactive slab diagnostics.",
          "timestamp" => "19:00:02",
          "meta" => %{
            "revision" => 1,
            "statement_count" => 24,
            "cache_status" => "seed"
          }
        }
      ]
    },
    %{
      "id" => "hetzner-fleet",
      "title" => "Hetzner Production Fleet",
      "renderer" => "fixed_80",
      "revision" => 1,
      "created_at" => "2026-10-24T19:05:00Z",
      "updated_at" => "2026-10-24T19:05:00Z",
      "ui_state" => %{"$target_env" => "prod", "$auto_heal" => true},
      "history" => [],
      "openui_code" => """
      $target_env = "prod"
      $auto_heal = true
      root = Dashboard("Hetzner Production Fleet", "Cluster hel1-prod", [banner, kpis, disk_prog, nodes_tbl, div_ctrl, ctrl_form])
      banner = Alert("success", "All 9 nodes healthy across hel1-dc2")
      kpis = Row([s_nodes, s_pg, s_llm])
      s_nodes = Stat("Nodes", "9/9", "+0", Sparkline([9, 9, 9, 9, 9, 9], "ok"))
      s_pg = Stat("PG18", "Active", "lag: 0ms", Sparkline([0, 0, 1, 0, 0], "ok"))
      s_llm = Stat("LiteLLM", "192ms", "-12ms", Sparkline([220, 210, 204, 198, 192], "info"))
      disk_prog = Progress("Primary Volume Usage", 62)
      nodes_tbl = Table([Col("Server", ["api-gateway-01", "pg-primary-01", "cache-node-01"]), Col("Status", ["OK", "OK", "OK"]), Col("Memory", ["1.2 GB", "31.4 GB", "4.8 GB"]), Col("CPU", ["14%", "42%", "8%"])])
      div_ctrl = Divider("Fleet Controls")
      ctrl_form = Form([f_env, f_heal], [btn_sync])
      f_env = Select("Environment", $target_env, ["prod", "staging", "dr-failover"])
      f_heal = Toggle("Auto-Heal Unhealthy Nodes", $auto_heal)
      btn_sync = Button("Filter Fleet View", @ToAssistant("Update the dashboard to focus on environment " + $target_env))
      """,
      "messages" => [
        %{
          "role" => "user",
          "text" =>
            "Create a Hetzner Production Fleet ops app with node health, PG18 & LiteLLM latency sparklines, server table, and environment controls.",
          "timestamp" => "19:05:00"
        },
        %{
          "role" => "assistant",
          "text" =>
            "Built the Hetzner Production Fleet app (`rev 1`) with 3 KPI cards, server status table, and interactive environment/auto-heal controls.",
          "timestamp" => "19:05:02",
          "meta" => %{
            "revision" => 1,
            "statement_count" => 15,
            "cache_status" => "seed"
          }
        }
      ]
    },
    %{
      "id" => "postgres-triage",
      "title" => "PostgreSQL 18 Query Triage",
      "renderer" => "fixed_80",
      "revision" => 1,
      "created_at" => "2026-10-24T19:10:00Z",
      "updated_at" => "2026-10-24T19:10:00Z",
      "ui_state" => %{"$min_ms" => "10ms", "$pool_mode" => "transaction"},
      "history" => [],
      "openui_code" => """
      $min_ms = "10ms"
      $pool_mode = "transaction"
      root = Dashboard("PostgreSQL 18 Telemetry", "Primary db-hel1-master", [
        Alert("info", "Operating normally under expected query load"),
        Row([
          Stat("Active Conn", "48/200", "+3", Sparkline([32, 35, 41, 45, 48], "info")),
          Stat("TPS", "1,842", "+120", Sparkline([1400, 1620, 1750, 1842], "ok")),
          Stat("Cache Hit", "99.4%", "buffer pool", Sparkline([99.1, 99.2, 99.4], "ok"))
        ]),
        Divider("Disk Saturation"),
        BarList([
          BarItem("/var/lib/postgresql", 68, "68% (136 GB / 200 GB)"),
          BarItem("/wal_archive", 22, "22% (22 GB / 100 GB)"),
          BarItem("/tmp", 5, "5% (1 GB / 20 GB)")
        ]),
        Divider("Top Queries"),
        Table([
          Col("Query ID", ["q_user_auth", "q_load_feed", "q_order_sum"]),
          Col("Calls", ["14,209", "8,912", "1,043"]),
          Col("Mean Time", ["1.2ms", "4.8ms", "18.4ms"]),
          Col("Status", ["OK", "OK", "WARN"])
        ]),
        Divider("PgBouncer & Query Triage Controls"),
        Form([
          Field("Slow Query Filter", $min_ms, "10ms"),
          Select("PgBouncer Mode", $pool_mode, ["transaction", "session", "statement"])
        ], [
          Button("Explain Slow Queries", @ToAssistant("Add EXPLAIN ANALYZE breakdown for queries slower than " + $min_ms + " in " + $pool_mode + " mode"))
        ])
      ])
      """,
      "messages" => [
        %{
          "role" => "user",
          "text" =>
            "Build a PostgreSQL 18 query triage app with connection/TPS sparklines, disk saturation bars, top queries table, and slow query filter controls.",
          "timestamp" => "19:10:00"
        },
        %{
          "role" => "assistant",
          "text" =>
            "Created PostgreSQL 18 Query Triage (`rev 1`) with disk saturation bars, `pg_stat_statements` table, and interactive PgBouncer/filter controls.",
          "timestamp" => "19:10:01",
          "meta" => %{
            "revision" => 1,
            "statement_count" => 12,
            "cache_status" => "seed"
          }
        }
      ]
    }
  ]

  @doc """
  Returns the directory where Studio apps (conversations) are persisted.
  """
  @spec apps_dir() :: String.t()
  def apps_dir do
    Application.get_env(
      :openui_tui,
      :studio_apps_dir,
      Path.expand("../../../priv/studio_apps", __DIR__)
    )
  end

  @doc """
  Ensures the studio apps directory exists and seeds the starter apps if empty.
  """
  @spec ensure_seeded!() :: :ok
  def ensure_seeded! do
    dir = apps_dir()
    File.mkdir_p!(dir)

    existing = Path.wildcard(Path.join(dir, "*.json"))

    if existing == [] do
      Enum.each(@starter_apps, &save_app!(&1, preserve_timestamp?: true))
    end

    :ok
  end

  @doc """
  Resets the studio apps directory cleanly back to the 3 starter apps (`memcached-live`,
  `hetzner-fleet`, `postgres-triage`).
  """
  @spec reset_seed_apps!() :: :ok
  def reset_seed_apps! do
    dir = apps_dir()
    File.mkdir_p!(dir)

    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    Enum.each(@starter_apps, &save_app!(&1, preserve_timestamp?: true))
    :ok
  end

  @doc """
  Executes `fun` inside an isolated temporary Studio apps directory seeded with the
  current apps (or clean starter apps), restoring the original `:studio_apps_dir` afterward.
  Prevents CLI test/iteration runs from mutating the user's saved apps on disk.
  """
  @spec with_sandbox((String.t() -> result), keyword()) :: result when result: var
  def with_sandbox(fun, opts \\ []) when is_function(fun, 1) do
    prev_dir = Application.get_env(:openui_tui, :studio_apps_dir)
    source_dir = apps_dir()

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "openui_studio_sandbox_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    try do
      if Keyword.get(opts, :clean_seeds?, true) do
        Application.put_env(:openui_tui, :studio_apps_dir, tmp_dir)
        reset_seed_apps!()
      else
        if File.dir?(source_dir) do
          File.cp_r!(source_dir, tmp_dir)
        end

        Application.put_env(:openui_tui, :studio_apps_dir, tmp_dir)
        ensure_seeded!()
      end

      fun.(tmp_dir)
    after
      File.rm_rf(tmp_dir)

      if prev_dir do
        Application.put_env(:openui_tui, :studio_apps_dir, prev_dir)
      else
        Application.delete_env(:openui_tui, :studio_apps_dir)
      end
    end
  end

  @doc """
  Lists all saved Studio app conversations in stable creation order (`created_at` ascending)
  so UI tab numbers (`#1`, `#2`, `#3`, ...) never jump around when chatting.
  """
  @spec list_apps() :: [map()]
  def list_apps do
    ensure_seeded!()

    apps_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, map} when is_map(map) -> [map]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&{Map.get(&1, "created_at", ""), Map.get(&1, "id", "")}, :asc)
  end

  @doc """
  Loads a specific Studio app by ID or 1-based list index.
  """
  @spec get_app(String.t() | pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def get_app(index) when is_integer(index) and index >= 1 do
    case Enum.at(list_apps(), index - 1) do
      nil -> {:error, :not_found}
      app -> {:ok, app}
    end
  end

  def get_app(id) when is_binary(id) do
    ensure_seeded!()
    path = Path.join(apps_dir(), "#{sanitize_id(id)}.json")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, map} -> {:ok, map}
            _ -> {:error, :not_found}
          end

        _ ->
          {:error, :not_found}
      end
    else
      # Try prefix or case-insensitive title match
      list_apps()
      |> Enum.find(fn app ->
        app["id"] == id or
          String.starts_with?(app["id"] || "", id) or
          String.contains?(String.downcase(app["title"] || ""), String.downcase(id))
      end)
      |> case do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    end
  end

  @doc """
  Persists a Studio app conversation to disk.
  """
  @spec save_app!(map(), keyword()) :: map()
  def save_app!(%{"id" => id} = app, opts \\ []) do
    File.mkdir_p!(apps_dir())
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ts =
      if Keyword.get(opts, :preserve_timestamp?, false) do
        Map.get(app, "updated_at") || now
      else
        now
      end

    updated = Map.put(app, "updated_at", ts)
    path = Path.join(apps_dir(), "#{sanitize_id(id)}.json")
    File.write!(path, Jason.encode!(updated, pretty: true))
    updated
  end

  @doc """
  Creates a new blank or seeded Studio app conversation.
  """
  @spec create_app!(String.t(), keyword()) :: map()
  def create_app!(title, opts \\ []) when is_binary(title) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    slug = slugify(title)
    id = Keyword.get(opts, :id, "#{slug}-#{rem(System.unique_integer([:positive]), 1000)}")
    renderer = Keyword.get(opts, :renderer, "fixed_80")

    initial_code =
      Keyword.get(
        opts,
        :openui_code,
        """
        root = Dashboard(#{inspect(title)}, "New OpenUI App — send a chat message to build or modify", [
          Alert("info", "App workspace initialized. Switch to Chat [Tab] and describe what you want to build!"),
          Row([
            Stat("Revision", "v1", "ready"),
            Stat("Renderer", #{inspect(renderer)}, "80-col")
          ])
        ])
        """
      )

    app = %{
      "id" => id,
      "title" => title,
      "renderer" => renderer,
      "revision" => 1,
      "created_at" => now,
      "updated_at" => now,
      "ui_state" => %{},
      "history" => [],
      "openui_code" => String.trim(initial_code),
      "messages" => [
        %{
          "role" => "assistant",
          "text" =>
            "Initialized new app workspace \"#{title}\". Describe the UI or dashboard you want to build, or press [Tab] to view the live app.",
          "timestamp" => Calendar.strftime(DateTime.utc_now(), "%H:%M:%S"),
          "meta" => %{"revision" => 1, "statement_count" => 2, "cache_status" => "init"}
        }
      ]
    }

    save_app!(app)
  end

  defp sanitize_id(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "-")
    |> String.trim("-")
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 28)
    |> case do
      "" -> "app"
      s -> s
    end
  end
end
