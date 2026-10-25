defmodule Mix.Tasks.Openui.Studio do
  @moduledoc """
  OpenUI Studio — A full-screen conversational TUI app builder where every chat conversation IS a live OpenUI app.

  ## Modes

  1. **Full-Screen Interactive Studio (`mix openui.studio`)**:
     Fills 100% of the terminal dimensions (`:io.columns()` × `:io.rows()`), enters the Alternate Screen
     Buffer (`\\e[?1049h`), and supports raw keystroke navigation:
     - `Tab`: Instantly toggle between `[F1:Chat]` and `[F2:Live App]`
     - `F1`–`F5`: Switch views (`[F1:Chat]`, `[F2:Live App]`, `[F3:Split]`, `[F4:Code]`, `[F5:Apps]`)
     - `F6` / `Ctrl+R`: Cycle TUI rendering engine (`fixed_80`, `owl`, `pure_ansi`, `table_rex`, `compact_ops`)
     - `↑` / `↓`: Focus interactive controls in the Live App
     - `←` / `→`: Cycle `Select` options or toggle `Toggle` switches in real time
     - `Enter`: Submit the chat prompt (or trigger the focused `Button` in App view when prompt is empty)
     - `/split` / `/code` / `/apps` / `/new <Title>` / `/switch <#>` / `/undo` / `/renderer` / `/quit`

  2. **Visual Walkthrough Demo (`mix openui.studio --demo`)**:
     Runs a non-blocking multi-view demonstration showing:
     - `[F1:Chat]` view with conversation turns
     - `[F2:Live App]` view with frameless embedded Memcached + BEAM telemetry & interactive controls
     - `[F3:Split]` side-by-side Chat + Live App view
     - `[F4:Code]` and `[F5:Apps]` views

  3. **Single-Turn CLI Evolution (`mix openui.studio --app <id> --prompt "..."`)**:
     Sends a prompt to a new or existing app conversation, updates its UI, persists to disk,
     and renders the resulting Studio view.
  """
  use Mix.Task

  alias OpenUITUI.CrashReporter
  alias OpenUITUI.Studio.{Chrome, Session, Store}

  @shortdoc "Launches OpenUI Studio (Full-Screen Chat + Tab-to-App TUI Workspace)"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          demo: :boolean,
          list: :boolean,
          app: :string,
          tab: :string,
          prompt: :string,
          new: :string,
          width: :integer,
          height: :integer
        ],
        aliases: [
          d: :demo,
          l: :list,
          a: :app,
          t: :tab,
          p: :prompt,
          n: :new,
          w: :width,
          h: :height
        ]
      )

    cond do
      Keyword.get(opts, :list, false) ->
        run_list_apps(opts)

      Keyword.get(opts, :demo, false) ->
        run_demo_walkthrough(opts)

      Keyword.has_key?(opts, :new) or Keyword.has_key?(opts, :prompt) or
          Keyword.has_key?(opts, :tab) ->
        run_one_shot(opts, argv)

      true ->
        run_interactive(opts)
    end
  end

  # ── 1. List Saved App Conversations ──────────────────────────────────────

  defp run_list_apps(opts) do
    {cols, _rows} = Chrome.detect_terminal_size()
    w = Keyword.get(opts, :width, cols)
    {:ok, session} = Session.start_link(initial_tab: :apps)
    IO.puts(Session.render_to_string(session, width: w))
  end

  # ── 2. One-Shot Non-Interactive Studio Invocation ────────────────────────

  defp run_one_shot(opts, argv) do
    {cols, rows} = Chrome.detect_terminal_size()
    w = Keyword.get(opts, :width, cols)
    h = Keyword.get(opts, :height, rows)

    initial_tab = parse_tab(Keyword.get(opts, :tab, "app"))
    {:ok, session} = Session.start_link(app_id: Keyword.get(opts, :app), initial_tab: initial_tab)

    if new_title = Keyword.get(opts, :new) do
      {:ok, _} = Session.create_new_app(session, new_title)
    end

    prompt = Keyword.get(opts, :prompt) || Enum.join(argv, " ")

    if String.trim(prompt) != "" do
      case Session.send_chat_message(session, prompt) do
        {:ok, _turn} ->
          :ok

        {:error, reason} ->
          IO.puts(IO.ANSI.red() <> "Error: #{inspect(reason)}" <> IO.ANSI.reset())
      end
    end

    Session.switch_tab(session, initial_tab)
    IO.puts(Session.render_to_string(session, width: w, height: h, fill_screen?: false))
  end

  # ── 3. Multi-Step Visual Walkthrough (`--demo`) ──────────────────────────

  defp run_demo_walkthrough(opts) do
    {cols, _rows} = Chrome.detect_terminal_size()
    w = Keyword.get(opts, :width, max(cols, 120))

    tmp_dir =
      Path.join(System.tmp_dir!(), "openui_studio_demo_#{System.unique_integer([:positive])}")

    Application.put_env(:openui_tui, :studio_apps_dir, tmp_dir)

    try do
      {:ok, session} = Session.start_link(app_id: "memcached-live", initial_tab: :chat)

      IO.puts(
        "\n" <>
          IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ STEP 1: OpenUI Studio — [1:Chat] Window (#{w} cols responsive) ═══" <>
          IO.ANSI.reset()
      )

      IO.puts(Session.render_to_string(session, width: w))

      # Step 2: Press [Tab] to switch to [2:Live App]
      {:ok, :app} = Session.toggle_chat_app_tab(session)

      IO.puts(
        "\n" <>
          IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ STEP 2: Press [Tab] ➔ [2:Live App] Window (Frameless Full-Width App + Controls) ═══" <>
          IO.ANSI.reset()
      )

      IO.puts(Session.render_to_string(session, width: w))

      # Step 3: Interact with controls & evolve to v2, then view in [3:Split] mode!
      {:ok, _} = Session.interact_focused_control(session, :next_val)
      {:ok, _} = Session.move_control_focus(session, :next)
      {:ok, action_res} = Session.interact_focused_control(session, :activate)

      {:ok, _} =
        Session.patch_app_code(
          session,
          """
          diag_alert = Alert("info", "Slab #2 Diagnostics: 120B chunk class has 0 evictions and optimal headroom")
          root = Panel("Memcached & BEAM Live Telemetry (127.0.0.1:11211)", [diag_alert, src, s_beam, b_ram, b_procs, kpis, div1, mem_bars, div2, slabs_tbl, div3, ctrl_form], "info")
          """,
          "Added live Slab #2 diagnostic banner from @ToAssistant action (\"#{action_res[:dispatched]}\")."
        )

      {:ok, :split} = Session.switch_tab(session, :split)

      IO.puts(
        "\n" <>
          IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ STEP 3: [3:Split] View — Side-by-Side Chat Conversation + Live App (v2) ═══" <>
          IO.ANSI.reset()
      )

      IO.puts(Session.render_to_string(session, width: w, height: 30))

      # Step 4: View [5:Apps] Conversation Directory
      {:ok, :apps} = Session.switch_tab(session, :apps)

      IO.puts(
        "\n" <>
          IO.ANSI.bright() <>
          IO.ANSI.cyan() <>
          "═══ STEP 4: [5:Apps] Tab — Every Conversation is a Persistent App ═══" <>
          IO.ANSI.reset()
      )

      IO.puts(Session.render_to_string(session, width: w))
    after
      File.rm_rf(tmp_dir)
      Application.delete_env(:openui_tui, :studio_apps_dir)
    end
  end

  # ── 4. Full-Screen Interactive Terminal Loop (`mix openui.studio`) ───────

  defp run_interactive(opts) do
    Store.ensure_seeded!()
    initial_tab = parse_tab(Keyword.get(opts, :tab, "split"))
    {:ok, session} = Session.start_link(app_id: Keyword.get(opts, :app), initial_tab: initial_tab)

    raw_mode? = enter_raw_mode()
    reader_pid = if raw_mode?, do: start_input_reader(self()), else: nil

    # Enter Alternate Screen Buffer & hide cursor
    IO.write(["\e[?1049h", "\e[?25l", IO.ANSI.clear(), IO.ANSI.home()])

    try do
      if raw_mode? do
        raw_loop(session)
      else
        line_loop(session)
      end
    rescue
      e ->
        path = CrashReporter.record_exception(e, __STACKTRACE__, %{mode: :interactive_studio})
        IO.write(["\e[?25h", "\e[?1049l"])

        IO.puts(
          IO.ANSI.red() <>
            "\nStudio encountered an error (saved crash report to #{path}):\n#{Exception.message(e)}" <>
            IO.ANSI.reset()
        )
    after
      if is_pid(reader_pid) and Process.alive?(reader_pid) do
        Process.unlink(reader_pid)
        Process.exit(reader_pid, :kill)
      end

      IO.write(["\e[?25h", "\e[?1049l"])
    end
  end

  defp enter_raw_mode do
    try do
      case :shell.start_interactive({:noshell, :raw}) do
        :ok -> true
        {:error, :already_started} -> true
        _ -> false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp start_input_reader(parent) do
    spawn_link(fn -> input_reader_loop(parent) end)
  end

  defp input_reader_loop(parent) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:studio_key, :eof})

      {:error, reason} ->
        send(parent, {:studio_key, {:error, reason}})

      "\e" ->
        seq = read_escape_token()
        send(parent, {:studio_key, {:escape, seq}})
        input_reader_loop(parent)

      ch ->
        send(parent, {:studio_key, ch})
        input_reader_loop(parent)
    end
  end

  defp read_escape_token do
    case IO.getn("", 1) do
      "[" ->
        read_csi_tail("[")

      "O" ->
        case IO.getn("", 1) do
          ch when is_binary(ch) -> "O" <> ch
          _ -> "O"
        end

      other when is_binary(other) ->
        other

      _ ->
        ""
    end
  end

  defp read_csi_tail(acc) when byte_size(acc) >= 12, do: acc

  defp read_csi_tail(acc) do
    case IO.getn("", 1) do
      "[" when acc == "[" ->
        # Linux console F1-F5: \e[[A .. \e[[E
        case IO.getn("", 1) do
          ch when is_binary(ch) -> "[[" <> ch
          _ -> "[["
        end

      <<b>> = ch when b in 0x40..0x7E ->
        # ECMA-48 CSI final byte (@ through ~, e.g. A, B, C, D, Z, ~)
        acc <> ch

      ch when is_binary(ch) ->
        read_csi_tail(acc <> ch)

      _ ->
        acc
    end
  end

  defp draw_fullscreen(session) do
    {cols, rows} = Chrome.detect_terminal_size()

    lines =
      Session.render_frame(session,
        width: cols,
        height: rows,
        fill_screen?: true,
        ansi?: true
      )

    # In raw mode (\r\n is required because OPOST/ONLCR may be disabled)
    IO.write([IO.ANSI.home(), Enum.join(lines, "\r\n")])
  end

  defp raw_loop(session) do
    draw_fullscreen(session)
    st = Session.get_state(session)
    refresh_ms = if Map.get(st, :chat_in_flight?, false), do: 250, else: 1_000

    receive do
      {:studio_key, :eof} ->
        :ok

      {:studio_key, {:error, _}} ->
        :ok

      # Ctrl+C (3) or Ctrl+D (4) or Ctrl+Q (17) -> exit cleanly
      {:studio_key, <<c>>} when c in [3, 4, 17] ->
        :ok

      # Tab (9) -> instant toggle between Split/Chat and Live App!
      {:studio_key, "\t"} ->
        Session.toggle_chat_app_tab(session)
        raw_loop(session)

      # Ctrl+N (14) -> create a new UI + its own fresh Chat!
      {:studio_key, <<14>>} ->
        cur_st = Session.get_state(session)
        next_num = length(cur_st.apps_list) + 1
        Session.create_new_app(session, "New OpenUI App ##{next_num}")
        raw_loop(session)

      # Ctrl+R (18) -> cycle TUI renderer!
      {:studio_key, <<18>>} ->
        Session.cycle_renderer(session)
        raw_loop(session)

      # Ctrl+S (19) -> switch to Split view!
      {:studio_key, <<19>>} ->
        Session.switch_tab(session, :split)
        raw_loop(session)

      # Ctrl+U (21) -> undo last revision!
      {:studio_key, <<21>>} ->
        Session.undo(session)
        raw_loop(session)

      # Ctrl+W (23) -> switch to the next UI + its Chat!
      {:studio_key, <<23>>} ->
        Session.cycle_app(session, :next)
        raw_loop(session)

      # Escape sequence (Arrow keys, Function keys F1-F6, Shift+Tab)
      {:studio_key, {:escape, seq}} ->
        handle_escape_seq(session, seq)
        raw_loop(session)

      # Backspace / Delete (127 or 8)
      {:studio_key, <<c>>} when c in [8, 127] ->
        Session.update_input_buffer(session, :backspace)
        raw_loop(session)

      # Enter (\r or \n)
      {:studio_key, c} when c in ["\r", "\n"] ->
        case handle_enter_key(session) do
          :quit -> :ok
          :continue -> raw_loop(session)
        end

      # Printable character — always appends to the prompt buffer so typing
      # numbers/letters (1, 2, 3, 4, 5, r, etc.) never interferes with chat!
      {:studio_key, ch} when is_binary(ch) ->
        Session.update_input_buffer(session, {:append, ch})
        raw_loop(session)
    after
      refresh_ms ->
        # Real-time refresh tick: 4Hz during active LLM generation, 1Hz for live StreamSources!
        raw_loop(session)
    end
  end

  defp handle_escape_seq(session, seq) do
    case seq do
      # F1-F5 (SS3 sequences: \eOP .. \eOT)
      "OP" ->
        Session.switch_tab(session, :chat)

      "OQ" ->
        Session.switch_tab(session, :app)

      "OR" ->
        Session.switch_tab(session, :split)

      "OS" ->
        Session.switch_tab(session, :code)

      "OT" ->
        Session.switch_tab(session, :apps)

      # Linux console / older xterm F1-F5 (\e[[A .. \e[[E)
      "[[A" ->
        Session.switch_tab(session, :chat)

      "[[B" ->
        Session.switch_tab(session, :app)

      "[[C" ->
        Session.switch_tab(session, :split)

      "[[D" ->
        Session.switch_tab(session, :code)

      "[[E" ->
        Session.switch_tab(session, :apps)

      # VT220 / xterm F1-F6 (\e[11~ .. \e[17~)
      "[11~" ->
        Session.switch_tab(session, :chat)

      "[12~" ->
        Session.switch_tab(session, :app)

      "[13~" ->
        Session.switch_tab(session, :split)

      "[14~" ->
        Session.switch_tab(session, :code)

      "[15~" ->
        Session.switch_tab(session, :apps)

      "[17~" ->
        Session.cycle_renderer(session)

      "[A" ->
        # Up arrow -> focus previous control
        Session.move_control_focus(session, :prev)

      "[B" ->
        # Down arrow -> focus next control
        Session.move_control_focus(session, :next)

      "[C" ->
        # Right arrow -> next option / toggle on focused control
        Session.interact_focused_control(session, :next_val)

      "[D" ->
        # Left arrow -> previous option / toggle on focused control
        Session.interact_focused_control(session, :prev_val)

      "[Z" ->
        # Shift+Tab -> toggle Chat ⇄ App
        Session.toggle_chat_app_tab(session)

      "[3~" ->
        # Delete key -> delete character
        Session.update_input_buffer(session, :backspace)

      _ ->
        :ok
    end
  end

  defp handle_enter_key(session) do
    state = Session.get_state(session)
    trimmed = String.trim(state.input_buffer)

    cond do
      trimmed == "" and state.active_tab in [:app, :split] ->
        # Pressing Enter in Live App view with empty prompt triggers the focused control!
        case Session.interact_focused_control(session, :activate, send_to_llm: false) do
          {:ok, %{kind: "Button", dispatched: prompt_str}}
          when is_binary(prompt_str) and prompt_str != "" ->
            spawn(fn ->
              Session.send_chat_message(session, prompt_str,
                pre_staged?: true,
                async_worker?: true
              )
            end)

          _ ->
            :ok
        end

        :continue

      trimmed == "" ->
        :continue

      true ->
        Session.update_input_buffer(session, {:set, ""})
        dispatch_command_or_prompt(session, trimmed, state.active_tab)
    end
  end

  defp line_loop(session) do
    {cols, rows} = Chrome.detect_terminal_size()

    lines =
      Session.render_frame(session,
        width: cols,
        height: max(rows - 2, 24),
        fill_screen?: true,
        ansi?: true
      )

    IO.write([IO.ANSI.home(), Enum.join(lines, "\n"), "\n"])

    case IO.gets("Studio Command / Prompt > ") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line when is_binary(line) ->
        state = Session.get_state(session)

        case dispatch_command_or_prompt(session, String.trim(line), state.active_tab) do
          :quit -> :ok
          :continue -> line_loop(session)
        end
    end
  end

  defp dispatch_command_or_prompt(_session, cmd, _tab) when cmd in ["/quit", "/exit", "/q"] do
    :quit
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["\t", "tab", "/tab"] do
    Session.toggle_chat_app_tab(session)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/chat", "/f1", "f1", "F1"] do
    Session.switch_tab(session, :chat)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/app", "/f2", "f2", "F2"] do
    Session.switch_tab(session, :app)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/split", "/f3", "f3", "F3"] do
    Session.switch_tab(session, :split)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/code", "/f4", "f4", "F4"] do
    Session.switch_tab(session, :code)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/apps", "/f5", "f5", "F5"] do
    Session.switch_tab(session, :apps)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/undo"] do
    Session.undo(session)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab)
       when cmd in ["/renderer", "/f6", "f6", "F6"] do
    Session.cycle_renderer(session)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/next", "/w"] do
    Session.cycle_app(session, :next)
    :continue
  end

  defp dispatch_command_or_prompt(session, cmd, _tab) when cmd in ["/prev"] do
    Session.cycle_app(session, :prev)
    :continue
  end

  defp dispatch_command_or_prompt(session, "/new", _tab) do
    st = Session.get_state(session)
    next_num = length(st.apps_list) + 1
    Session.create_new_app(session, "New OpenUI App ##{next_num}")
    :continue
  end

  defp dispatch_command_or_prompt(session, "/new " <> title, _tab) do
    Session.create_new_app(session, String.trim(title))
    :continue
  end

  defp dispatch_command_or_prompt(session, "/switch " <> target, _tab) do
    trimmed = String.trim(target)

    arg =
      case Integer.parse(trimmed) do
        {idx, ""} -> idx
        _ -> trimmed
      end

    Session.switch_app(session, arg)
    :continue
  end

  defp dispatch_command_or_prompt(session, "/patch " <> patch_code, _tab) do
    Session.patch_app_code(session, patch_code)
    :continue
  end

  defp dispatch_command_or_prompt(session, "/set " <> rest, _tab) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
      [_var, val] ->
        Session.interact_focused_control(session, {:set_val, val})

      _ ->
        :ok
    end

    :continue
  end

  defp dispatch_command_or_prompt(session, "/model " <> target, _tab) do
    trimmed = String.trim(target)

    if trimmed != "" do
      spawn(fn ->
        Session.send_chat_message(session, "use " <> trimmed, async_worker?: true)
      end)
    end

    :continue
  end

  defp dispatch_command_or_prompt(session, "/reset", _tab) do
    Store.reset_seed_apps!()
    st = Session.get_state(session)
    cur_id = get_in(st, [:current_app, "id"]) || "memcached-live"
    Session.switch_app(session, cur_id)
    :continue
  end

  defp dispatch_command_or_prompt(session, prompt, _tab) do
    spawn(fn ->
      Session.send_chat_message(session, prompt, async_worker?: true)
    end)

    :continue
  end

  defp parse_tab("app"), do: :app
  defp parse_tab("split"), do: :split
  defp parse_tab("code"), do: :code
  defp parse_tab("apps"), do: :apps
  defp parse_tab(_), do: :chat
end
