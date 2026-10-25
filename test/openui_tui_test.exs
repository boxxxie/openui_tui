defmodule OpenUITUITest do
  use ExUnit.Case, async: false

  alias OpenUITUI.{
    BindingEngine,
    Cache,
    LayoutGuard,
    LiteLLMClient,
    LiveSession,
    Memcached,
    Renderers,
    Resolver,
    SourceNormalizer,
    SpendGuard,
    Telemetry,
    TUIRenderer
  }

  alias OpenUITUI.Memcached.Probe

  @ansi_regex ~r/\e\[[0-9;]*m/

  defp visible_length(line) do
    line |> String.replace(@ansi_regex, "") |> String.length()
  end

  setup do
    test_jsonl =
      Path.join(
        System.tmp_dir!(),
        "openui_tui_test_#{System.unique_integer([:positive])}.jsonl"
      )

    Application.put_env(:openui_tui, :telemetry_jsonl_path, test_jsonl)
    SpendGuard.reset_session!()
    Cache.clear_l1()

    on_exit(fn ->
      File.rm_rf(test_jsonl)
      SpendGuard.set_budget_limit(1.00)
    end)

    {:ok, jsonl_path: test_jsonl}
  end

  describe "80-Column Invariant, Sparklines, Fractional BarList & Skeletons" do
    test "renders exact 80-column lines while mid-stream forward references are unresolved" do
      partial_symbols = %{
        "root" =>
          {"Panel",
           [
             "Cluster Health",
             [{:ref, "kpis"}, {:ref, "bars"}, {:ref, "nodes_tbl"}],
             "info"
           ]},
        "kpis" => {"Row", [[{:ref, "cpu_stat"}, {:ref, "req_stat"}]]},
        "cpu_stat" =>
          {"Stat", ["Avg CPU", "68%", "+12%", {"Sparkline", [[40, 50, 55, 60, 68], "warn"]}]},
        "req_stat" => {"Stat", ["Req/s", "14.2K", "+5%", {:ref, "unresolved_spark"}]},
        "bars" =>
          {"BarList",
           [
             [
               {"BarItem", ["web-ingest", 78.4, "78.4%"]},
               {"BarItem", ["oban-workers", 34.1, "34.1%"]}
             ]
           ]}
      }

      lines =
        partial_symbols
        |> Resolver.resolve_root()
        |> TUIRenderer.render(ansi?: true, tick: 2)

      # Every single rendered line inside the Panel must be exactly 80 visible graphemes wide
      for line <- lines do
        assert visible_length(line) == 80
      end

      plain_output = Enum.map_join(lines, "\n", &String.replace(&1, @ansi_regex, ""))

      assert plain_output =~ "▁▄▅▆█"
      assert plain_output =~ "web-ingest"
      assert plain_output =~ "[ ⠹ resolving nodes_tbl…"
    end

    test "parses and renders the canonical 80-column cluster health & scaling form example" do
      canonical_openui = """
      root = Panel("Cluster Health & Scaling", [kpis, div1, nodes_tbl, div2, scale_form], "info")
      $target_env = "prod-us"
      $replicas = "6"
      $drain_nodes = false
      kpis = Row([cpu_stat, req_stat])
      cpu_stat = Stat("Avg CPU", "68%", "+12%", cpu_spark)
      cpu_spark = Sparkline([42, 45, 48, 51, 55, 62, 60, 64, 66, 68], "warn")
      req_stat = Stat("Throughput", "14.2K/s", "+5.4%", req_spark)
      req_spark = Sparkline([10, 11, 11, 12, 12, 13, 13, 14, 14, 14], "ok")
      div1 = Divider("Worker Nodes")
      nodes_tbl = Table([c_node, c_role, c_mem, c_status], [
        ["beam-01", "ingest", "4.2 GB", "healthy"],
        ["beam-02", "ingest", "7.8 GB", "degraded"],
        ["beam-03", "worker", "3.1 GB", "healthy"]
      ])
      c_node = Col("Node", 14, "left")
      c_role = Col("Role", 12, "left")
      c_mem = Col("Memory", 12, "right")
      c_status = Col("Status", 14, "left")
      div2 = Divider("Scale Deployment")
      scale_form = Form([f_env, f_rep, f_drain], [btn_apply])
      f_env = Select("Environment", $target_env, ["prod-us", "prod-eu", "staging"])
      f_rep = Field("Replicas", $replicas, "1..32")
      f_drain = Toggle("Cordone & drain degraded nodes first", $drain_nodes)
      btn_apply = Button("Apply Scale", Action([@ToAssistant("Scale " + $target_env + " to " + $replicas + " replicas")]))
      """

      lines = OpenUITUI.resolve_and_render_80col(canonical_openui, ansi?: true)
      assert length(lines) >= 15

      for line <- lines do
        assert visible_length(line) == 80
      end

      plain = Enum.map_join(lines, "\n", &String.replace(&1, @ansi_regex, ""))
      assert plain =~ "Cluster Health & Scaling"
      assert plain =~ "beam-01"
      assert plain =~ "◀ prod-us ▶"
      assert plain =~ "[ Apply Scale ]"
    end

    test "LayoutGuard demotes nested Panels, unwraps overloaded Rows, and rescales oversized Tables" do
      raw_ast =
        {"Panel",
         [
           "Outer Title",
           [
             {"Panel", ["Nested Panel", [{"Text", ["Inside nested"]}]]},
             {"Row",
              [
                [
                  {"Stat", ["S1", "1"]},
                  {"Stat", ["S2", "2"]},
                  {"Stat", ["S3", "3"]},
                  {"Stat", ["S4", "4"]}
                ]
              ]},
             {"Table",
              [
                [
                  {"Col", ["C1", 30, "left"]},
                  {"Col", ["C2", 30, "left"]},
                  {"Col", ["C3", 30, "left"]},
                  {"Col", ["C4", 30, "left"]},
                  {"Col", ["C5_dropped", 30, "left"]}
                ],
                [["a", "b", "c", "d", "e"]]
              ]}
           ]
         ]}

      clamped = LayoutGuard.clamp(raw_ast)
      {"Panel", ["Outer Title", [demoted_panel, unwrapped_row, clamped_table]]} = clamped

      # Nested panel demoted to Stack with Divider
      assert {"Stack", [[{"Divider", ["Nested Panel"]} | _], 0]} = demoted_panel

      # 4-item Row unwrapped to vertical Stack
      assert {"Stack", [_, 1]} = unwrapped_row

      # 5-column Table capped at 4 columns and widths rescaled to fit 76 inner cols
      {"Table", [kept_cols, [trimmed_row]]} = clamped_table
      assert length(kept_cols) == 4
      assert trimmed_row == ["a", "b", "c", "d"]

      total_w = Enum.reduce(kept_cols, 0, fn {"Col", [_, w | _]}, acc -> acc + w end)
      assert total_w <= 65
    end
  end

  describe "Live Memcached Probe, Generic SourceNormalizer, BindingEngine & LiveSession" do
    test "Memcached.Probe fetches live stats from 127.0.0.1:11211 and computes $live_* bindings" do
      assert {:ok, summary, bindings} = Probe.introspect_summary("127.0.0.1", 11_211)
      assert summary =~ "Memcached (127.0.0.1:11211) pre-flight snapshot"
      assert is_binary(bindings["$live_ops_sec"])
      assert is_binary(bindings["$live_hit_ratio"])
      assert is_list(bindings["$live_ops_history"])
      assert length(bindings["$live_ops_history"]) == 18
      assert is_list(bindings["$live_slab_bars"])
    end

    test "SourceNormalizer and BindingEngine normalize BEAM, TCP, and CLI sources safely" do
      # 1. BEAM memory introspection
      beam_info = SourceNormalizer.inspect_metric_source("beam", "erlang:memory", "term")
      assert beam_info.row_count == 1
      assert "total_mb" in beam_info.available_keys

      # 2. BEAM top processes introspection
      proc_info =
        SourceNormalizer.inspect_metric_source("beam", "recon:proc_count_memory", "term")

      assert proc_info.row_count >= 1
      assert "pid" in proc_info.available_keys

      # 3. TCP Memcached KV normalization
      tcp_info = SourceNormalizer.inspect_metric_source("tcp", "127.0.0.1:11211|stats\r\n", "kv")
      assert tcp_info.row_count == 1
      assert "uptime" in tcp_info.available_keys

      # 4. Disallowed shell command is rejected safely
      assert {:error, {:command_not_allowlisted, "rm"}} =
               SourceNormalizer.fetch_and_normalize("exec", "rm -rf /", "columns")

      # 5. BindingEngine evaluates value, spark_value, rows, and bars
      symbols =
        OpenUILang.parse_symbols("""
        b1 = Bind($total_ram, "beam_mem", "total_mb", "value", "{val} MB")
        b2 = Bind($ram_spark, "beam_mem", "total_mb", "spark_value")
        """)

      {:ok, rows} = SourceNormalizer.fetch_and_normalize("beam", "erlang:memory", "term")

      {_engine, bound} =
        BindingEngine.evaluate_source(%BindingEngine{}, symbols, "beam_mem", rows)

      assert bound["$total_ram"] =~ "MB"
      assert length(bound["$ram_spark"]) == 18
    end

    test "LiveSession runs Memcached & BEAM StreamSources without clobbering user ui_state" do
      openui_code = """
      root = Panel("Memcached Live Telemetry (127.0.0.1:11211)", [src, s_beam, b_ram, kpis, div1, mem_bars, div2, slabs_tbl, div3, ctrl_form], "info")
      src = StreamSource("memcached", "127.0.0.1:11211", 1000)
      s_beam = StreamSource("beam", "beam", "erlang:memory", "term", 1000)
      b_ram = Bind($beam_ram, "beam", "total_mb", "value", "{val} MB")
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
      btn_analyze = Button("Diagnose Slab", Action([@ToAssistant("Analyze eviction pressure on slab " + $slab_inspect + " (" + $live_diagnostic_summary + ")")]))
      """

      {:ok, session} = LiveSession.start_link()
      :ok = LiveSession.load_openui(session, openui_code)

      # User changes $slab_inspect to "4" in the UI
      :ok = LiveSession.put_ui_state(session, "$slab_inspect", "4")

      # Even if the LLM re-streams `$slab_inspect = "1"`, user's `"4"` in ui_state is preserved!
      :ok = LiveSession.load_openui(session, "$slab_inspect = \"1\"")

      # Execute a 1Hz data-plane poll cycle against live Memcached + BEAM memory
      {:ok, lines} = LiveSession.poll_now(session)

      for line <- lines do
        assert visible_length(line) == 80
      end

      plain = Enum.map_join(lines, "\n", &String.replace(&1, @ansi_regex, ""))
      assert plain =~ "Memcached Live Telemetry (127.0.0.1:112"
      assert plain =~ "Total RAM"
      assert plain =~ "◀ 4 ▶"

      # Dispatching the button action interpolates both $slab_inspect ("4") and live metrics!
      {:ok, action_resolved} = LiveSession.dispatch_action(session, "btn_analyze")
      {"Action", [[{"ToAssistant", [prompt_str]}]]} = action_resolved
      assert prompt_str =~ "Analyze eviction pressure on slab 4 ("
      assert prompt_str =~ "hit_ratio="
    end
  end

  describe "Memcached L2 & Cachex L1 two-tier caching" do
    test "stores and retrieves values across Cachex (L1) and Memcached (L2) on 127.0.0.1:11211" do
      assert {:ok, version} = Memcached.ping()
      assert is_binary(version) and version != ""

      key =
        Cache.build_key("/v1/chat/completions", "gemini-2.5-flash-lite", %{
          "test_nonce" => System.unique_integer([:positive])
        })

      entry = %{
        model: "gemini-2.5-flash-lite",
        endpoint: "/v1/chat/completions",
        call_id: "test-call-1",
        content: ~s|root = Dashboard("Cached", "Sub", [])|,
        prompt_tokens: 100,
        completion_tokens: 20,
        total_tokens: 120,
        raw_cost_usd: 0.000012,
        effective_cost_usd: 0.000012,
        duration_ms: 210
      }

      assert :miss == Cache.fetch(key)
      assert :ok == Cache.put(key, entry, 300)

      # 1. Hit in L1 Cachex
      assert {:hit, :l1_cachex, ^entry} = Cache.fetch(key)

      # 2. Evict L1 Cachex -> Hit in L2 Memcached and re-warm L1
      assert :ok == Cache.clear_l1()
      assert {:hit, :l2_memcached, ^entry} = Cache.fetch(key)

      # 3. Subsequent fetch hits L1 Cachex again
      assert {:hit, :l1_cachex, ^entry} = Cache.fetch(key)

      assert :ok == Cache.delete(key)
      assert :miss == Cache.fetch(key)
    end
  end

  describe "5 Elixir TUI Renderers & Streaming Simulation" do
    test "compares :fixed_80, :pure_ansi, :owl, :table_rex, and :compact_ops on OpenUI Lang dashboard" do
      openui_code = """
      $env = "prod"
      root = Dashboard("Hetzner Infrastructure", "hel1-prod", [banner, kpis, cpu_bar, srv_table, notes])
      banner = Alert("success", "All 9 Hetzner servers online — LiteLLM proxy healthy")
      kpis = Row([Stat("Servers", "9", "hel1 + fsn1"), Stat("Postgres", "18.6", "2 replicas"), Stat("Spend Cap", "$1.00", "openui-tui-maker")])
      cpu_bar = Progress("Cluster Memory Utilization", 64)
      srv_table = Table([Col("Host", ["api-gateway-01", "pg-primary-01", "cache-node-01"]), Col("IP", ["10.0.1.10", "10.0.1.20", "10.0.1.30"]), Col("Role", ["AI Proxy", "Primary DB", "Staging"])])
      notes = Panel("Active Guardrails", ["L1 Cachex + L2 Memcached enabled", "Jev SystemOne treated as close-to-free", "JSONL telemetry active"])
      """

      comparison = OpenUITUI.compare_renderers(openui_code)
      assert comparison.errors == []
      assert comparison.compression_savings_pct > 20.0

      for r <- Renderers.available_renderers() do
        info = Map.fetch!(comparison.renderers, r)
        assert is_binary(info.output)
        assert info.output =~ "Hetzner Infrastructure"
        assert info.output =~ "api-gateway-01"
        assert info.output_bytes > 100
      end

      frames = OpenUITUI.simulate_streaming(openui_code, :pure_ansi, 60)
      assert length(frames) > 3
      assert List.last(frames).incomplete == false
      assert List.last(frames).rendered =~ "Hetzner Infrastructure"
    end
  end

  describe "Live LiteLLM + TypeSafe Jev + Version Telemetry + Budget Overrun Report" do
    test "routes with Jev, generates OpenUI with gemini-2.5-flash-lite, caches in Memcached, compares version tags, and generates spend report on overrun",
         %{jsonl_path: jsonl_path} do
      prompt =
        "Build a compact Dashboard('Service Status', 'prod', [Alert('success', 'OK'), Row([Stat('Uptime', '99.98%', '30d')]), Table([Col('Service', ['api', 'db']), Col('Latency', ['12ms', '4ms'])])])"

      # 1. Version v1-full-prompt
      OpenUITUI.set_version_tags(
        program_version: "0.1.0-v1",
        prompt_version: "v1-full-prompt",
        experiment_tag: "test-v1"
      )

      {:ok, gen_v1} =
        OpenUITUI.generate_tui(prompt,
          model: "gemini-2.5-flash-lite",
          use_jev_router: false
        )

      assert is_binary(gen_v1.openui_code)
      assert gen_v1.root["type"] == "Dashboard"

      # 2. Version v2-jev-compact (uses TypeSafe Jev + compact prompt)
      OpenUITUI.set_version_tags(
        program_version: "0.2.0-v2",
        prompt_version: "v2-jev-compact",
        experiment_tag: "test-v2-jev"
      )

      {:ok, gen_v2} =
        OpenUITUI.generate_tui(prompt,
          model: "gemini-2.5-flash-lite",
          use_jev_router: true
        )

      assert is_binary(gen_v2.openui_code)
      assert gen_v2.root["type"] == "Dashboard"
      assert gen_v2.jev_routing.effective_cost_usd == 0.0
      assert gen_v2.prompt_tokens < gen_v1.prompt_tokens

      # 3. Verify L2 Memcached hit when L1 Cachex is cleared
      Cache.clear_l1()

      {:ok, gen_v2_cached} =
        OpenUITUI.generate_tui(prompt,
          model: "gemini-2.5-flash-lite",
          use_jev_router: true
        )

      assert gen_v2_cached.cache_status == "hit_l2_memcached"

      # 4. Verify JSONL telemetry version comparison
      comparison = Telemetry.compare_versions(jsonl_path)
      assert comparison.total_api_events >= 3
      assert map_size(comparison.versions) == 2

      # 5. Test SpendGuard overrun workflow: set a micro budget cap and record spend crossing it
      SpendGuard.set_budget_limit(0.000005)

      assert {:budget_exceeded, post_call_report} =
               SpendGuard.record_call(%{
                 model: "gemini-2.5-flash-lite",
                 raw_cost_usd: 0.000010
               })

      assert File.exists?(post_call_report.report_path)

      # Jev calls remain allowed because Jev is considered close-to-free
      assert :ok == SpendGuard.check_budget("typesafe/jev-latest")

      # Uncached Gemini call is blocked by pre-call gate and triggers SpendReport generation!
      uncached_messages = [
        %{"role" => "user", "content" => "Uncached call #{System.unique_integer([:positive])}"}
      ]

      assert {:error, {:budget_exceeded, report}} =
               LiteLLMClient.chat_completion(uncached_messages,
                 model: "gemini-2.5-flash-lite",
                 bypass_cache: true
               )

      assert File.exists?(report.report_path)
      assert report.markdown =~ "OpenUI TUI Maker — LLM Spend & Telemetry Review Report"
      assert report.markdown =~ "BUDGET LIMIT REACHED"
      assert report.openui_code =~ "Dashboard("

      rendered_report = OpenUITUI.render(report.openui_code, :owl)
      assert rendered_report =~ "OpenUI TUI Spend & Telemetry Review"
    end
  end

  describe "OpenUI Studio (Chat Window + Tab-to-App TUI Workspace)" do
    test "manages conversations as apps, toggles Chat ⇄ Live App via Tab, interacts with controls, patches UI, and undoes revisions" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "openui_studio_test_#{System.unique_integer([:positive])}"
        )

      Application.put_env(:openui_tui, :studio_apps_dir, tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
        Application.delete_env(:openui_tui, :studio_apps_dir)
      end)

      {:ok, studio} =
        OpenUITUI.Studio.Session.start_link(app_id: "memcached-live", initial_tab: :chat)

      # 1. Chat tab renders 80-column Studio chrome
      chat_lines = OpenUITUI.Studio.Session.render_frame(studio, ansi?: false)
      assert Enum.all?(chat_lines, &(String.length(&1) == 80))
      chat_str = Enum.join(chat_lines, "\n")
      assert chat_str =~ "[★ F1:Chat]"
      assert chat_str =~ "Memcached & BEAM Live Telemetry"

      # 2. Press [Tab] -> toggles to :app (Live App)
      assert {:ok, :app} = OpenUITUI.Studio.Session.toggle_chat_app_tab(studio)
      app_lines = OpenUITUI.Studio.Session.render_frame(studio, ansi?: false)
      assert Enum.all?(app_lines, &(String.length(&1) == 80))
      app_str = Enum.join(app_lines, "\n")
      assert app_str =~ "[★ F2:Live App]"
      assert app_str =~ "Interactive App Controls & State Bindings"

      # 3. Interact with Select control ($slab_inspect) and Button (@ToAssistant)
      assert {:ok, %{kind: "Select", var: "$slab_inspect", value: next_slab}} =
               OpenUITUI.Studio.Session.interact_focused_control(studio, :next_val)

      assert is_binary(next_slab) and next_slab != ""

      assert {:ok, 1} = OpenUITUI.Studio.Session.move_control_focus(studio, :next)

      assert {:ok, %{kind: "Button", dispatched: dispatched_prompt}} =
               OpenUITUI.Studio.Session.interact_focused_control(studio, :activate)

      assert dispatched_prompt =~
               "Analyze eviction pressure and chunk sizing for slab class #{next_slab}"

      # 4. Patch the app conversationally -> bumps revision to v2, then /undo restores v1
      assert {:ok, patched_app} =
               OpenUITUI.Studio.Session.patch_app_code(
                 studio,
                 ~s|diag = Alert("info", "Slab 2 healthy")|,
                 "Added Slab 2 diagnostic alert"
               )

      assert patched_app["revision"] == 2

      assert {:ok, restored_app} = OpenUITUI.Studio.Session.undo(studio)
      assert restored_app["revision"] == 1

      # 5. Create a brand-new conversation/app and switch between apps
      assert {:ok, new_app} =
               OpenUITUI.Studio.Session.create_new_app(studio, "Redis Sentinel Watch")

      assert new_app["title"] == "Redis Sentinel Watch"
      assert length(OpenUITUI.Studio.Store.list_apps()) == 4

      # 6. Verify full-screen responsive rendering (128x36) and unit-suffixed Sparklines (1.1M, 290k, 700M)
      llm_code_with_suffixes = """
      root = Dashboard("Memcached Metrics", "Local Instance", [
        Row([
          Stat("Gets", "1.2M", "+50k", Sparkline([1.1M, 1.15M, 1.2M], "info")),
          Stat("Sets", "300k", "+10k", Sparkline([290k, 295k, 300k], "info")),
          Stat("Used Memory", "750MB / 1GB", "75%", Sparkline([700M, 725M, 750M], "info"))
        ])
      ])
      """

      assert {:ok, _} =
               OpenUITUI.Studio.Session.patch_app_code(
                 studio,
                 llm_code_with_suffixes,
                 "Updated with unit-suffixed sparklines"
               )

      assert {:ok, :split} = OpenUITUI.Studio.Session.switch_tab(studio, :split)

      fullscreen_lines =
        OpenUITUI.Studio.Session.render_frame(studio,
          width: 128,
          height: 36,
          fill_screen?: true,
          ansi?: false
        )

      assert length(fullscreen_lines) == 36
      assert Enum.all?(fullscreen_lines, &(String.length(&1) == 128))
      fullscreen_str = Enum.join(fullscreen_lines, "\n")
      assert fullscreen_str =~ "1.2M (+50k)"
      assert fullscreen_str =~ "300k (+10k)"
    end

    @tag timeout: 120_000
    test "Harness CLI hooks verify keystroke DSL, AST torture suite, and live prompt tracing in sandbox" do
      smoke = OpenUITUI.Studio.Harness.run_smoke_suite(live_llm?: true)
      assert smoke.failed == 0
      assert smoke.passed == 4
    end
  end
end
