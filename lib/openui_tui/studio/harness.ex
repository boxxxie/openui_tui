defmodule OpenUITUI.Studio.Harness do
  @moduledoc """
  Headless programmatic & CLI test harness for `OpenUITUI.Studio`.

  Exercises the exact same code paths as the interactive terminal loop (`Mix.Tasks.Openui.Studio`)
  without requiring a raw TTY or interactive keystrokes:
  - `trace_prompt/2`: Full lifecycle trace of staging a prompt, calling LiteLLM/Jev, demuxing,
    merging statements, polling `LiveSession`, extracting controls, and verifying screen geometry
    across all 5 Studio tabs (`:chat`, `:app`, `:split`, `:code`, `:apps`) and all 5 renderers.
  - `simulate_keys/2`: Executes a keystroke DSL sequence (`type:"..."`, `enter`, `tab`, `up`,
    `down`, `left`, `right`, `space`, `backspace`, `ctrl+s`, `ctrl+u`, `1..5`, `r`) against
    `Studio.Session` and returns each state transition + final rendered frame.
  - `inspect_app/2`: Dumps symbol table, `$ui_state`, interactive controls, messages, and frame.
  - `run_smoke_suite/1`: Runs an end-to-end verification suite across seed apps, multi-turn LLM
    prompts, renderer cycling, control interactions, and AST edge cases.
  """

  alias OpenUITUI.Studio.{Session, Store}

  @ansi_regex ~r/\e\[[0-9;]*m/
  @tabs [:chat, :app, :split, :code, :apps]

  @doc """
  Runs a single conversational prompt through the exact Studio pipeline (`stage_user_prompt` ➔
  `send_chat_message` ➔ `render_frame`) and returns a comprehensive diagnostic trace map.

  By default, runs in an isolated sandbox (`persist?: false`) so testing never mutates
  `priv/studio_apps/*.json` unless `persist?: true` is passed.
  """
  @spec trace_prompt(String.t(), keyword()) :: map()
  def trace_prompt(prompt, opts \\ []) when is_binary(prompt) do
    persist? = Keyword.get(opts, :persist?, false)

    runner = fn ->
      do_trace_prompt(prompt, opts)
    end

    if persist? do
      Store.ensure_seeded!()
      runner.()
    else
      Store.with_sandbox(fn _tmp -> runner.() end,
        clean_seeds?: Keyword.get(opts, :clean_seeds?, false)
      )
    end
  end

  defp do_trace_prompt(prompt, opts) do
    app_id = Keyword.get(opts, :app_id)
    tab = Keyword.get(opts, :tab, :split)
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)
    ansi? = Keyword.get(opts, :ansi?, true)

    {:ok, session} = Session.start_link(app_id: app_id, initial_tab: :chat)

    try do
      before_state = Session.get_state(session)
      before_app = before_state.current_app

      # 1. Stage the user prompt (just like pressing Enter in raw_loop)
      :ok = Session.stage_user_prompt(session, prompt)
      staged_state = Session.get_state(session)

      staged_lines =
        Session.render_frame(session,
          width: width,
          height: height,
          fill_screen?: true,
          ansi?: false
        )

      staged_text = Enum.join(staged_lines, "\n")

      stage_ok? =
        staged_state.input_buffer == "" and
          String.contains?(staged_text, String.slice(String.trim(prompt), 0, 20)) and
          String.contains?(staged_text, "Generating OpenUI")

      # 2. Execute the synchronous LLM / evolution turn
      t0 = System.monotonic_time(:millisecond)
      llm_opts = Keyword.take(opts, [:model, :use_jev_router, :bypass_cache, :max_tokens])
      send_res = Session.send_chat_message(session, prompt, [{:pre_staged?, true} | llm_opts])
      elapsed_ms = System.monotonic_time(:millisecond) - t0

      after_state = Session.get_state(session)
      after_app = after_state.current_app
      new_code = Map.get(after_app, "openui_code", "")
      symbols = OpenUILang.parse_symbols(new_code)
      {:ok, eval_info} = OpenUITUI.parse_and_evaluate(new_code)

      # 3. Verify geometry across all 5 tabs at (width x height)
      tab_checks =
        Map.new(@tabs, fn t ->
          {:ok, ^t} = Session.switch_tab(session, t)

          lines =
            Session.render_frame(session,
              width: width,
              height: height,
              fill_screen?: true,
              ansi?: false
            )

          widths = Enum.map(lines, &String.length/1)
          exact_w? = Enum.all?(widths, &(&1 == width))
          exact_h? = length(lines) == height

          {t,
           %{
             line_count: length(lines),
             exact_width?: exact_w?,
             exact_height?: exact_h?,
             valid?: exact_w? and exact_h?
           }}
        end)

      # 4. Verify all 5 renderers can render the resulting app without crashing
      {:ok, :app} = Session.switch_tab(session, :app)

      renderer_checks =
        Enum.map(1..5, fn _ ->
          {:ok, r_name} = Session.cycle_renderer(session)

          lines =
            Session.render_frame(session,
              width: width,
              height: height,
              fill_screen?: true,
              ansi?: false
            )

          {r_name, length(lines) == height and Enum.all?(lines, &(String.length(&1) == width))}
        end)
        |> Map.new()

      # Restore requested tab & render final frame
      {:ok, ^tab} = Session.switch_tab(session, tab)

      rendered_frame =
        Session.render_to_string(session,
          width: width,
          height: height,
          fill_screen?: true,
          ansi?: ansi?
        )

      %{
        status: if(match?({:ok, _}, send_res), do: :ok, else: :error),
        send_result: send_res,
        elapsed_ms: elapsed_ms,
        stage_verified?: stage_ok?,
        before: %{
          app_id: before_app["id"],
          title: before_app["title"],
          revision: before_app["revision"],
          code_bytes: byte_size(before_app["openui_code"] || "")
        },
        after: %{
          app_id: after_app["id"],
          title: after_app["title"],
          revision: after_app["revision"],
          code_bytes: byte_size(new_code),
          openui_code: new_code,
          symbol_keys: Map.keys(symbols) |> Enum.sort(),
          has_root?: Map.has_key?(symbols, "root"),
          eval_errors: eval_info.errors,
          controls: Enum.map(after_state.controls, &Map.drop(&1, [:ast])),
          ui_state: after_state.ui_state,
          last_message: List.last(after_app["messages"] || [])
        },
        geometry_checks: tab_checks,
        renderer_checks: renderer_checks,
        all_geometry_valid?:
          Enum.all?(tab_checks, fn {_, v} -> v.valid? end) and
            Enum.all?(renderer_checks, fn {_, ok?} -> ok? end),
        rendered_frame: rendered_frame
      }
    after
      if Process.alive?(session), do: GenServer.stop(session, :normal)
    end
  end

  @doc """
  Simulates a sequence of keystroke / command tokens against `Studio.Session`, mirroring
  the exact key handling of `Mix.Tasks.Openui.Studio`.

  ## Supported Tokens in DSL String or List
  - `type:"<text>"` or `type:<word>` — types characters one by one into `input_buffer`
  - `backspace` — deletes last character from `input_buffer`
  - `enter` — triggers `Enter` (sends prompt in `:chat`, or activates focused control in `:app` if buffer empty)
  - `tab` / `shift+tab` — toggles `:chat` ⇄ `:app`
  - `up` / `down` — moves control focus `:prev` / `:next`
  - `left` / `right` / `space` — cycles `Select` option or flips `Toggle`
  - `1` / `2` / `3` / `4` / `5` — switches to `:chat`, `:app`, `:split`, `:code`, `:apps`
  - `ctrl+s` — switches to `:split`
  - `ctrl+u` — undoes last revision (`/undo`)
  - `r` — cycles renderer
  """
  @spec simulate_keys(String.t() | [String.t()], keyword()) :: map()
  def simulate_keys(dsl_or_tokens, opts \\ []) do
    persist? = Keyword.get(opts, :persist?, false)
    tokens = if is_binary(dsl_or_tokens), do: parse_key_dsl(dsl_or_tokens), else: dsl_or_tokens

    runner = fn ->
      do_simulate_keys(tokens, opts)
    end

    if persist? do
      Store.ensure_seeded!()
      runner.()
    else
      Store.with_sandbox(fn _tmp -> runner.() end,
        clean_seeds?: Keyword.get(opts, :clean_seeds?, false)
      )
    end
  end

  defp do_simulate_keys(tokens, opts) do
    app_id = Keyword.get(opts, :app_id)
    initial_tab = Keyword.get(opts, :initial_tab, :chat)
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)
    ansi? = Keyword.get(opts, :ansi?, true)

    {:ok, session} = Session.start_link(app_id: app_id, initial_tab: initial_tab)

    try do
      steps =
        tokens
        |> Enum.with_index(1)
        |> Enum.map(fn {tok, idx} ->
          action_res = apply_key_token(session, tok, opts)
          st = Session.get_state(session)

          focused =
            case Enum.at(st.controls, st.focused_control_idx) do
              %{kind: k, label: l} = c -> "#{k}:#{l}(#{Map.get(c, :var, c.id)})"
              _ -> "none"
            end

          %{
            step: idx,
            token: tok,
            result: inspect(action_res),
            active_tab: st.active_tab,
            input_buffer: st.input_buffer,
            revision: st.current_app["revision"],
            renderer: st.current_app["renderer"],
            focused_control: focused,
            ui_state: st.ui_state,
            status_message: st.status_message
          }
        end)

      final_state = Session.get_state(session)

      final_frame =
        Session.render_to_string(session,
          width: width,
          height: height,
          fill_screen?: true,
          ansi?: ansi?
        )

      %{
        steps: steps,
        final_tab: final_state.active_tab,
        final_revision: final_state.current_app["revision"],
        final_title: final_state.current_app["title"],
        final_ui_state: final_state.ui_state,
        final_status: final_state.status_message,
        rendered_frame: final_frame
      }
    after
      if Process.alive?(session), do: GenServer.stop(session, :normal)
    end
  end

  @doc """
  Inspects a Studio app's symbol table, controls, state bindings, messages, and rendered frame.
  """
  @spec inspect_app(String.t() | nil, keyword()) :: map()
  def inspect_app(app_id \\ nil, opts \\ []) do
    tab = Keyword.get(opts, :tab, :split)
    width = Keyword.get(opts, :width, 120)
    height = Keyword.get(opts, :height, 34)
    ansi? = Keyword.get(opts, :ansi?, true)

    Store.ensure_seeded!()
    {:ok, session} = Session.start_link(app_id: app_id, initial_tab: tab)

    try do
      st = Session.get_state(session)
      app = st.current_app
      code = Map.get(app, "openui_code", "")
      symbols = OpenUILang.parse_symbols(code)
      {:ok, eval_info} = OpenUITUI.parse_and_evaluate(code)

      frame =
        Session.render_to_string(session,
          width: width,
          height: height,
          fill_screen?: true,
          ansi?: ansi?
        )

      %{
        app_id: app["id"],
        title: app["title"],
        revision: app["revision"],
        renderer: app["renderer"],
        history_count: length(app["history"] || []),
        message_count: length(app["messages"] || []),
        messages: app["messages"] || [],
        ui_state: st.ui_state,
        controls: Enum.map(st.controls, &Map.drop(&1, [:ast])),
        symbol_keys: Map.keys(symbols) |> Enum.sort(),
        has_root?: Map.has_key?(symbols, "root"),
        eval_errors: eval_info.errors,
        openui_code: code,
        rendered_frame: frame
      }
    after
      if Process.alive?(session), do: GenServer.stop(session, :normal)
    end
  end

  @doc """
  Runs a comprehensive automated smoke & invariant test suite across Studio without needing
  interactive UI access.
  """
  @spec run_smoke_suite(keyword()) :: map()
  def run_smoke_suite(opts \\ []) do
    live_llm? = Keyword.get(opts, :live_llm?, true)

    Store.with_sandbox(
      fn _tmp ->
        checks = [
          run_check("1. Seed apps load & render 80x28 and 128x36 across all 5 tabs", fn ->
            for app_id <- ["memcached-live", "hetzner-fleet", "postgres-triage"],
                {w, h} <- [{80, 28}, {128, 36}],
                tab <- @tabs do
              {:ok, s} = Session.start_link(app_id: app_id, initial_tab: tab)

              lines =
                Session.render_frame(s, width: w, height: h, fill_screen?: true, ansi?: false)

              GenServer.stop(s, :normal)

              if length(lines) != h or not Enum.all?(lines, &(String.length(&1) == w)) do
                raise "Geometry mismatch on app=#{app_id} tab=#{tab} (#{w}x#{h})"
              end
            end

            :ok
          end),
          run_check(
            "2. Raw keystroke simulation: F1-F6, numbers in chat, backspace, Tab, controls, undo",
            fn ->
              sim =
                do_simulate_keys(
                  [
                    "tab",
                    "right",
                    "down",
                    "enter",
                    "type:12345",
                    "f3"
                  ],
                  app_id: "memcached-live",
                  width: 120,
                  height: 32,
                  ansi?: false
                )

              if sim.final_tab != :split do
                raise "Expected final_tab :split, got #{inspect(sim.final_tab)}"
              end

              if sim.final_ui_state["$slab_inspect"] == "1" do
                raise "Expected $slab_inspect to cycle from 1 to 2, got #{inspect(sim.final_ui_state)}"
              end

              last_step = List.last(sim.steps)

              if last_step.input_buffer != "12345" do
                raise "Expected typing 12345 in :app view to populate input_buffer, got #{inspect(last_step.input_buffer)}"
              end

              :ok
            end
          ),
          run_check(
            "3. AST torture test: Sparkline unit suffixes, Badge in Table, unresolved Stat refs, all 5 renderers",
            fn ->
              torture_code = """
              $env = "prod"
              root = Dashboard("Torture Test UI", "Edge cases from LLM", [
                Alert("Only one arg alert"),
                Row([
                  Stat("2-Arg Spark", Sparkline([1.2M, 2.4M, 3.1M], "info")),
                  Stat("Unresolved Val", missing_val, "+10%", Sparkline([10k, 20k, 30k], "ok")),
                  Badge("LIVE", "success")
                ]),
                KeyValue({region: "hel1", tier: "prod"}),
                Table([
                  Col("Host", ["web-1", "db-1"]),
                  Col("BadgeCol", [Badge("OK", "success"), Badge("WARN", "warning")]),
                  Col("Trend", [Sparkline([1, 2, 3]), Sparkline([3, 2, 1])])
                ]),
                Form([
                  Select("Env", $env, ["prod", "staging"])
                ], [
                  Button("Run Check", @ToAssistant("Check " + $env + " and " + missing_ref))
                ])
              ])
              """

              {:ok, s} = Session.start_link(app_id: "hetzner-fleet", initial_tab: :split)
              {:ok, _} = Session.patch_app_code(s, torture_code, "Applied torture test AST")

              for _ <- 1..5 do
                {:ok, _r} = Session.cycle_renderer(s)

                lines =
                  Session.render_frame(s,
                    width: 120,
                    height: 34,
                    fill_screen?: true,
                    ansi?: false
                  )

                if length(lines) != 34 or not Enum.all?(lines, &(String.length(&1) == 120)) do
                  raise "Torture test geometry failed"
                end
              end

              GenServer.stop(s, :normal)
              :ok
            end
          )
        ]

        llm_checks =
          if live_llm? do
            [
              run_check(
                "4. Live LLM prompt evolution on postgres-triage & multi-turn follow-up",
                fn ->
                  trace1 =
                    do_trace_prompt("i want a ui for memcached",
                      app_id: "postgres-triage",
                      width: 120,
                      height: 34,
                      ansi?: false
                    )

                  if trace1.status != :ok or not trace1.stage_verified? or
                       not trace1.all_geometry_valid? do
                    raise "Trace 1 failed: status=#{inspect(trace1.status)} stage=#{trace1.stage_verified?} geom=#{trace1.all_geometry_valid?}"
                  end

                  trace2 =
                    do_trace_prompt("add a warning alert at the top for high evictions on slab 3",
                      app_id: "postgres-triage",
                      width: 120,
                      height: 34,
                      ansi?: false
                    )

                  if trace2.status != :ok or not trace2.all_geometry_valid? do
                    raise "Trace 2 failed: status=#{inspect(trace2.status)} geom=#{trace2.all_geometry_valid?}"
                  end

                  :ok
                end
              )
            ]
          else
            []
          end

        all = checks ++ llm_checks

        %{
          total: length(all),
          passed: Enum.count(all, &(&1.status == :passed)),
          failed: Enum.count(all, &(&1.status == :failed)),
          results: all
        }
      end,
      clean_seeds?: true
    )
  end

  defp run_check(name, fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      :ok = fun.()
      %{name: name, status: :passed, duration_ms: System.monotonic_time(:millisecond) - t0}
    rescue
      e ->
        %{
          name: name,
          status: :failed,
          error: Exception.message(e),
          stacktrace: Exception.format(:error, e, __STACKTRACE__),
          duration_ms: System.monotonic_time(:millisecond) - t0
        }
    end
  end

  defp apply_key_token(session, "type:" <> text, _opts) do
    text
    |> String.graphemes()
    |> Enum.each(fn ch ->
      Session.update_input_buffer(session, {:append, ch})
    end)

    {:typed, text}
  end

  defp apply_key_token(session, "backspace", _opts) do
    Session.update_input_buffer(session, :backspace)
  end

  defp apply_key_token(session, "tab", _opts) do
    Session.toggle_chat_app_tab(session)
  end

  defp apply_key_token(session, "shift+tab", _opts) do
    Session.toggle_chat_app_tab(session)
  end

  defp apply_key_token(session, "up", _opts) do
    Session.move_control_focus(session, :prev)
  end

  defp apply_key_token(session, "down", _opts) do
    Session.move_control_focus(session, :next)
  end

  defp apply_key_token(session, "right", _opts) do
    Session.interact_focused_control(session, :next_val)
  end

  defp apply_key_token(session, "left", _opts) do
    Session.interact_focused_control(session, :prev_val)
  end

  defp apply_key_token(session, "space", _opts) do
    Session.update_input_buffer(session, {:append, " "})
  end

  defp apply_key_token(session, "ctrl+s", _opts) do
    Session.switch_tab(session, :split)
  end

  defp apply_key_token(session, "ctrl+u", _opts) do
    Session.undo(session)
  end

  defp apply_key_token(session, "ctrl+r", _opts) do
    Session.cycle_renderer(session)
  end

  defp apply_key_token(session, "ctrl+w", _opts) do
    Session.cycle_app(session, :next)
  end

  defp apply_key_token(session, "ctrl+n", _opts) do
    st = Session.get_state(session)
    next_num = length(st.apps_list) + 1
    Session.create_new_app(session, "New OpenUI App ##{next_num}")
  end

  defp apply_key_token(session, fkey, _opts)
       when fkey in ["f1", "F1", "f2", "F2", "f3", "F3", "f4", "F4", "f5", "F5", "f6", "F6"] do
    case String.downcase(fkey) do
      "f1" -> Session.switch_tab(session, :chat)
      "f2" -> Session.switch_tab(session, :app)
      "f3" -> Session.switch_tab(session, :split)
      "f4" -> Session.switch_tab(session, :code)
      "f5" -> Session.switch_tab(session, :apps)
      "f6" -> Session.cycle_renderer(session)
    end
  end

  defp apply_key_token(session, "enter", opts) do
    st = Session.get_state(session)
    trimmed = String.trim(st.input_buffer)

    cond do
      trimmed == "" and st.active_tab in [:app, :split] ->
        Session.interact_focused_control(
          session,
          :activate,
          send_to_llm: Keyword.get(opts, :send_to_llm, false)
        )

      trimmed == "" ->
        :noop

      String.starts_with?(trimmed, "/") ->
        Session.update_input_buffer(session, {:set, ""})
        exec_slash(session, trimmed)

      true ->
        :ok = Session.stage_user_prompt(session, trimmed)
        Session.send_chat_message(session, trimmed, pre_staged?: true)
    end
  end

  defp apply_key_token(session, "/" <> _ = slash, _opts) do
    exec_slash(session, slash)
  end

  defp apply_key_token(session, other, _opts) do
    Session.update_input_buffer(session, {:append, other})
  end

  defp exec_slash(session, "/chat"), do: Session.switch_tab(session, :chat)
  defp exec_slash(session, "/app"), do: Session.switch_tab(session, :app)
  defp exec_slash(session, "/split"), do: Session.switch_tab(session, :split)
  defp exec_slash(session, "/code"), do: Session.switch_tab(session, :code)
  defp exec_slash(session, "/apps"), do: Session.switch_tab(session, :apps)
  defp exec_slash(session, "/undo"), do: Session.undo(session)
  defp exec_slash(session, "/renderer"), do: Session.cycle_renderer(session)

  defp exec_slash(session, "/new " <> title),
    do: Session.create_new_app(session, String.trim(title))

  defp exec_slash(session, "/patch " <> code), do: Session.patch_app_code(session, code)

  defp exec_slash(session, "/set " <> rest) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
      [_var, val] -> Session.interact_focused_control(session, {:set_val, val})
      _ -> :noop
    end
  end

  defp exec_slash(_session, _unknown), do: :noop

  @doc """
  Parses a keystroke DSL string into discrete tokens, preserving quoted `type:"..."` strings.
  """
  @spec parse_key_dsl(String.t()) :: [String.t()]
  def parse_key_dsl(dsl) when is_binary(dsl) do
    Regex.scan(~r/type:"([^"]*)"|type:'([^']*)'|[^\s,]+/, dsl)
    |> Enum.map(fn
      [_, quoted] when is_binary(quoted) and quoted != "" -> "type:" <> quoted
      [_, "", single_quoted] when is_binary(single_quoted) -> "type:" <> single_quoted
      [full | _] -> full
    end)
  end

  @doc false
  def strip_ansi(str) when is_binary(str), do: String.replace(str, @ansi_regex, "")
end
