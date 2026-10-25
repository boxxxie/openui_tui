defmodule OpenUITUI.Studio.Chrome do
  @moduledoc """
  Responsive, full-screen terminal UI renderer for the OpenUI Studio workspace.

  Supports both:
  - Dynamic full-screen terminal geometry (`width` × `height` from `:io.columns()` / `:io.rows()`)
    with unified rounded borders (`╭─...─╮`, `├─...─┤`, `╰─...─╯`) and bottom-anchored dock.
  - 5 workspace views:
    - `:chat` (`[F1:Chat]`) — Full-width conversation history + live App status pill + bottom prompt input
    - `:app` (`[F2:Live App]`) — Full-width frameless embedded OpenUI app + interactive control deck
    - `:split` (`[F3:Split]`) — Side-by-side Chat (left pane) + Live App (right pane)
    - `:code` (`[F4:Code]`) — Line-numbered OpenUI Lang DSL source + reactive `$state` inspector
    - `:apps` (`[F5:Apps]`) — Directory of all saved conversation-apps
  """

  alias OpenUITUI.TUIRenderer

  @ansi_regex ~r/\e\[[0-9;]*m/

  @tabs [
    {:chat, "F1:Chat"},
    {:app, "F2:Live App"},
    {:split, "F3:Split"},
    {:code, "F4:Code"},
    {:apps, "F5:Apps"}
  ]

  @doc """
  Detects the current terminal `{columns, rows}` with sensible fallbacks.
  """
  @spec detect_terminal_size() :: {pos_integer(), pos_integer()}
  def detect_terminal_size do
    cols =
      case :io.columns() do
        {:ok, c} when is_integer(c) and c >= 60 -> c
        _ -> 120
      end

    rows =
      case :io.rows() do
        {:ok, r} when is_integer(r) and r >= 20 -> r
        _ -> 36
      end

    {cols, rows}
  end

  @doc """
  Renders the complete Studio frame as a list of lines, each exactly `width` visible graphemes wide.
  When `fill_screen?: true`, pads the main viewport vertically so the total frame is `height` lines tall.
  """
  @spec render(map(), keyword()) :: [String.t()]
  def render(state, opts \\ []) do
    ansi? = Keyword.get(opts, :ansi?, true)
    outer_w = Keyword.get(opts, :width, 80)
    total_h = Keyword.get(opts, :height, 32)
    fill_screen? = Keyword.get(opts, :fill_screen?, false)
    inner_w = max(outer_w - 4, 40)

    app = state.current_app
    title = Map.get(app, "title", "Untitled App")
    rev = Map.get(app, "revision", 1)
    renderer = Map.get(app, "renderer", "fixed_80")
    live_info = Map.get(state, :live_info, %{active?: false, tick: 0, sources: []})

    header_lines =
      render_header(
        state.current_app,
        state.apps_list,
        title,
        rev,
        renderer,
        live_info,
        state.active_tab,
        outer_w,
        inner_w,
        ansi?
      )

    dock_lines = render_bottom_dock(state, outer_w, inner_w, ansi?)
    target_body_h = max(total_h - length(header_lines) - length(dock_lines), 6)

    raw_body_lines =
      case state.active_tab do
        :chat -> render_chat_tab(state, inner_w, ansi?)
        :app -> render_app_tab(state, inner_w, target_body_h, fill_screen?, ansi?)
        :split -> render_split_tab(state, outer_w, inner_w, target_body_h, ansi?)
        :code -> render_code_tab(state, inner_w, target_body_h, fill_screen?, ansi?)
        :apps -> render_apps_tab(state, inner_w, ansi?)
      end

    body_lines =
      if fill_screen? do
        fit_vertical_viewport(raw_body_lines, target_body_h, inner_w, state.active_tab, ansi?)
      else
        raw_body_lines
      end

    header_lines ++ body_lines ++ dock_lines
  end

  @doc """
  Renders the Studio frame as a newline-joined string.
  """
  @spec render_to_string(map(), keyword()) :: String.t()
  def render_to_string(state, opts \\ []) do
    render(state, opts) |> Enum.join("\n")
  end

  # ── Top Studio Header, UI Switcher & View Tab Bar (4 lines) ──────────────

  defp render_header(
         current_app,
         apps_list,
         title,
         rev,
         _renderer,
         live_info,
         active_tab,
         outer_w,
         inner_w,
         ansi?
       ) do
    live_tag =
      if Map.get(live_info, :active?, false) do
        pulse = if rem(Map.get(live_info, :tick, 0), 2) == 0, do: "●", else: "◎"
        " • #{pulse} LIVE 1Hz"
      else
        ""
      end

    totals = compute_chat_totals(current_app)
    app_model = Map.get(current_app || %{}, "model", OpenUITUI.Config.default_model())
    app_effort = Map.get(current_app || %{}, "reasoning_effort")
    model_badge = OpenUITUI.Config.format_model_badge(app_model, app_effort)

    totals_tag =
      "Model: #{model_badge} │ Chat: #{format_int(totals.total_tokens)} tok ($#{format_usd(totals.total_cost_usd, 4)})"

    max_title = max(outer_w - 52, 14)

    top_label =
      "─ ◆ OpenUI Studio ── Active UI: #{truncate(title, max_title)} (v#{rev}#{live_tag}) "

    top_border = "╭" <> TUIRenderer.fit_cell(top_label, outer_w - 2, "left", "─") <> "╮"

    # Line 2: Always-visible UI Switcher + Active Model + Cumulative Chat Token/$ Total
    current_id = Map.get(current_app || %{}, "id")
    ui_prefix = "Apps (Ctrl+W): "

    ui_pills_plain =
      apps_list
      |> Enum.with_index(1)
      |> Enum.map_join(" ", fn {a, idx} ->
        short_t = truncate(to_string(a["title"] || a["id"]), 13)

        if a["id"] == current_id do
          "[★##{idx}:#{short_t}]"
        else
          "[##{idx}:#{short_t}]"
        end
      end)

    left_apps_str = ui_prefix <> ui_pills_plain

    ui_line_plain =
      if String.length(totals_tag) + 20 <= inner_w do
        max_left = max(inner_w - String.length(totals_tag) - 2, 18)
        clipped_left = truncate(left_apps_str, max_left)

        pad =
          String.duplicate(
            " ",
            max(inner_w - String.length(clipped_left) - String.length(totals_tag), 1)
          )

        clipped_left <> pad <> totals_tag
      else
        left_apps_str
      end

    # Line 3: View Mode Tabs (F1-F5)
    app_count = length(apps_list)

    tab_pills =
      Enum.map_join(@tabs, "  ", fn {tab_id, label} ->
        full_label = if tab_id == :apps, do: "#{label}(#{app_count})", else: label

        if tab_id == active_tab do
          color("[★ #{full_label}]", :active_tab, ansi?)
        else
          color("[  #{full_label}]", :muted, ansi?)
        end
      end)

    visible_tabs_len =
      @tabs
      |> Enum.map_join("  ", fn {tab_id, label} ->
        full_label = if tab_id == :apps, do: "#{label}(#{app_count})", else: label
        if tab_id == active_tab, do: "[★ #{full_label}]", else: "[  #{full_label}]"
      end)
      |> String.length()

    hint = if inner_w >= 86, do: "[Tab: Toggle View]", else: ""
    pad_len = max(inner_w - visible_tabs_len - String.length(hint), 0)

    tab_line_inner =
      if visible_tabs_len + String.length(hint) <= inner_w do
        tab_pills <> String.duplicate(" ", pad_len) <> color(hint, :cyan, ansi?)
      else
        plain_tabs =
          @tabs
          |> Enum.map_join(" ", fn {tab_id, label} ->
            if tab_id == active_tab, do: "[★#{label}]", else: "[#{label}]"
          end)

        color(TUIRenderer.fit_cell(plain_tabs, inner_w, "left"), :active_tab, ansi?)
      end

    vis_len =
      if visible_tabs_len + String.length(hint) <= inner_w,
        do: visible_tabs_len + pad_len + String.length(hint),
        else: inner_w

    sep_border = "├" <> String.duplicate("─", outer_w - 2) <> "┤"

    [
      color(top_border, :header, ansi?),
      frame_plain(ui_line_plain, inner_w, :green, ansi?),
      frame_line(tab_line_inner, vis_len, inner_w, ansi?),
      color(sep_border, :header, ansi?)
    ]
  end

  # ── 1. CHAT TAB ──────────────────────────────────────────────────────────

  defp render_chat_tab(state, inner_w, ansi?) do
    lines = build_chat_column_lines(state, inner_w, ansi?)
    Enum.map(lines, fn {ansi_str, vis_len} -> frame_line(ansi_str, vis_len, inner_w, ansi?) end)
  end

  defp build_chat_column_lines(state, col_w, ansi?) do
    app = state.current_app
    messages = Map.get(app, "messages", [])
    recent_msgs = Enum.take(messages, -8)
    totals = compute_chat_totals(app)

    totals_banner =
      if state.active_tab == :chat do
        rule_txt =
          TUIRenderer.fit_cell(
            "─── ◆ Chat Usage Total: #{totals.turns} turns • #{format_int(totals.total_tokens)} tok (#{format_int(totals.prompt_tokens)} in / #{format_int(totals.completion_tokens)} out) • $#{format_usd(totals.total_cost_usd, 6)} ",
            col_w,
            "left",
            "─"
          )

        [styled_cell(rule_txt, col_w, :cyan, ansi?)]
      else
        []
      end

    msg_lines =
      if recent_msgs == [] do
        [
          styled_cell(
            "  No messages yet. Type a prompt below to build or modify this app!",
            col_w,
            :muted,
            ansi?
          )
        ]
      else
        Enum.flat_map(recent_msgs, &render_chat_message_col(&1, col_w, ansi?))
      end

    if state.active_tab == :chat do
      stmt_count = count_statements(Map.get(app, "openui_code", ""))
      ctrl_count = length(state.controls)

      banner_rule =
        TUIRenderer.fit_cell(
          "─── Live App Preview (#{Map.get(app, "title", "App")} • v#{Map.get(app, "revision", 1)} • #{stmt_count} stmts • #{ctrl_count} controls — [Tab] App / [F3] Split) ",
          col_w,
          "left",
          "─"
        )

      preview_lines =
        (state.rendered_app_lines || [])
        |> Enum.take(6)
        |> Enum.map(fn line ->
          vis = visible_len(line)

          if vis <= col_w do
            {line <> String.duplicate(" ", max(col_w - vis, 0)), col_w}
          else
            styled_cell(strip_ansi(line), col_w, :default, ansi?)
          end
        end)

      totals_banner ++
        msg_lines ++
        [
          styled_cell("", col_w, :default, ansi?),
          styled_cell(banner_rule, col_w, :cyan, ansi?)
        ] ++ preview_lines
    else
      msg_lines
    end
  end

  @spinners ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @slash_commands [
    {"/model <name> [low|med|high]",
     "Switch Gemini model (e.g. /model argon low, /model 3.8-flash)"},
    {"/new <title>", "Create a new OpenUI app + chat conversation"},
    {"/app <1|2|3>", "Switch to another OpenUI app by number or id"},
    {"/undo", "Revert the active UI to its previous revision"},
    {"/reset", "Reset starter apps to clean defaults"},
    {"/help", "Show keyboard shortcuts and slash commands"},
    {"/quit", "Exit OpenUI Studio"}
  ]

  defp render_chat_message_col(msg, col_w, ansi?) do
    role = Map.get(msg, "role", "user")
    text = Map.get(msg, "text", "")
    ts = Map.get(msg, "timestamp", "")
    meta = Map.get(msg, "meta", %{})

    if is_map(meta) and Map.get(meta, "pending") == true do
      started_ms = Map.get(meta, "started_at_ms", System.monotonic_time(:millisecond))
      elapsed_ms = max(System.monotonic_time(:millisecond) - started_ms, 0)
      elapsed_str = :erlang.float_to_binary(elapsed_ms / 1000.0, decimals: 1) <> "s"
      spin_idx = rem(div(elapsed_ms, 200), length(@spinners))
      spinner = Enum.at(@spinners, spin_idx)
      step_str = Map.get(meta, "step", text)
      turn_model = Map.get(meta, "model", "gemini-3.8-flash")
      jev_intent = Map.get(meta, "jev_intent")

      route_hint =
        case jev_intent do
          "ask_question_or_meta" ->
            "└─ ● Route: Q&A Answer (keeping current UI unchanged)"

          "build_or_modify_ui" ->
            "└─ ● Route: Patching OpenUI AST components..."

          _ ->
            "└─ ● Live 1Hz UI continues running while AI processes your request"
        end

      header_line =
        styled_cell(
          "#{spinner} Thinking... (#{elapsed_str} • #{turn_model})",
          col_w,
          :yellow,
          ansi?
        )

      wrapped_step =
        step_str
        |> wrap_text(max(col_w - 6, 16))
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} ->
          prefix = if idx == 0, do: "├─ ", else: "│  "
          styled_cell(prefix <> line, col_w, :bright, ansi?)
        end)

      [
        header_line
        | wrapped_step ++
            [
              styled_cell(route_hint, col_w, :cyan, ansi?),
              styled_cell("", col_w, :default, ansi?)
            ]
      ]
    else
      case role do
        "user" ->
          wrapped_user =
            text
            |> wrap_text(max(col_w - 4, 16))
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} ->
              if idx == 0 do
                styled_cell("❯ " <> line, col_w, :green, ansi?)
              else
                styled_cell("  " <> line, col_w, :bright, ansi?)
              end
            end)

          wrapped_user ++ [styled_cell("", col_w, :default, ansi?)]

        "action" ->
          wrapped_act =
            text
            |> wrap_text(max(col_w - 4, 16))
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} ->
              prefix = if idx == 0, do: "⚡ ", else: "  "
              styled_cell(prefix <> line, col_w, :yellow, ansi?)
            end)

          wrapped_act ++ [styled_cell("", col_w, :default, ansi?)]

        _ ->
          rev = Map.get(meta, "revision")
          stmts = Map.get(meta, "statement_count")
          cache = to_string(Map.get(meta, "cache_status", "live"))
          cost = Map.get(meta, "cost_usd", 0.0)
          raw_cost = Map.get(meta, "raw_cost_usd", cost)
          prompt_tok = Map.get(meta, "prompt_tokens", 0)
          comp_tok = Map.get(meta, "completion_tokens", 0)
          total_tok = Map.get(meta, "total_tokens", prompt_tok + comp_tok)
          dur_ms = Map.get(meta, "duration_ms")
          jev_intent = Map.get(meta, "jev_intent")
          turn_model = Map.get(meta, "model", "gemini-3.8-flash")

          dur_str =
            if is_number(dur_ms) and dur_ms > 0,
              do: " • #{:erlang.float_to_binary(dur_ms / 1000.0, decimals: 1)}s",
              else: ""

          # Separate main prose from Δ UI Changes block if present
          {main_prose, diff_lines} = split_prose_and_diff(text)

          tool_step_lines =
            case jev_intent do
              "create_new_app" ->
                [
                  styled_cell(
                    "├─ ✔ Jido.ClassifyIntent ➔ create_new_app",
                    col_w,
                    :cyan,
                    ansi?
                  ),
                  styled_cell(
                    "├─ ✔ Jido.CreateApp ➔ v#{rev || 1} (#{stmts || "?"} statements • new App + fresh Chat)",
                    col_w,
                    :green,
                    ansi?
                  )
                ]

              "switch_model" ->
                [
                  styled_cell(
                    "├─ ✔ Jido.ClassifyIntent ➔ switch_model",
                    col_w,
                    :cyan,
                    ansi?
                  ),
                  styled_cell(
                    "├─ ✔ Jido.SwitchModel ➔ #{turn_model}",
                    col_w,
                    :green,
                    ansi?
                  )
                ]

              "ask_question_or_meta" ->
                [
                  styled_cell(
                    "├─ ✔ Jido.ClassifyIntent ➔ ask_question_or_meta",
                    col_w,
                    :cyan,
                    ansi?
                  ),
                  styled_cell(
                    "├─ ✔ Jido.AnswerQuestion ➔ UI v#{rev || 1} kept (#{turn_model})",
                    col_w,
                    :green,
                    ansi?
                  )
                ]

              "build_or_modify_ui" ->
                base_steps = [
                  styled_cell(
                    "├─ ✔ Jido.ClassifyIntent ➔ build_or_modify_ui",
                    col_w,
                    :cyan,
                    ansi?
                  ),
                  styled_cell(
                    "├─ ✔ Jido.EvolveUI ➔ v#{rev || 1} (#{stmts || "?"} statements)",
                    col_w,
                    :green,
                    ansi?
                  )
                ]

                extra_diff =
                  diff_lines
                  |> Enum.take(2)
                  |> Enum.map(fn dl ->
                    styled_cell("│  " <> String.trim(dl), col_w, :muted, ansi?)
                  end)

                base_steps ++ extra_diff

              _ ->
                if rev do
                  [
                    styled_cell(
                      "├─ ✔ Init OpenUI AST ➔ v#{rev} (#{stmts || "?"} statements • #{ts})",
                      col_w,
                      :muted,
                      ansi?
                    )
                  ]
                else
                  []
                end
            end

          wrapped_prose =
            main_prose
            |> wrap_text(max(col_w - 4, 16))
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} ->
              prefix = if idx == 0, do: "● ", else: "  "
              styled_cell(prefix <> line, col_w, :default, ansi?)
            end)

          usage_line =
            cond do
              cache in ["seed", "init"] ->
                "└─ starter UI • 0 tok • $0.0000"

              String.starts_with?(cache, "hit_") ->
                "└─ #{turn_model} • #{format_int(total_tok)} tok (#{format_int(prompt_tok)} in / #{format_int(comp_tok)} out) • $0.0000 (cached, saved $#{format_usd(raw_cost, 4)})"

              true ->
                "└─ #{turn_model} • #{format_int(total_tok)} tok (#{format_int(prompt_tok)} in / #{format_int(comp_tok)} out) • $#{format_usd(cost, 6)}#{dur_str}"
            end

          receipt_lines =
            if is_map(meta) and map_size(meta) > 0 do
              [styled_cell(usage_line, col_w, :info, ansi?)]
            else
              []
            end

          tool_step_lines ++
            wrapped_prose ++ receipt_lines ++ [styled_cell("", col_w, :default, ansi?)]
      end
    end
  end

  defp split_prose_and_diff(text) when is_binary(text) do
    case String.split(text, "\nΔ UI Changes", parts: 2) do
      [prose, diff_rest] ->
        diff_lines =
          diff_rest
          |> String.split("\n")
          |> Enum.drop(1)
          |> Enum.reject(&(String.trim(&1) == ""))

        {String.trim(prose), diff_lines}

      [prose] ->
        {String.trim(prose), []}
    end
  end

  # ── 2. LIVE APP TAB (Frameless Embedded App + Control Deck) ──────────────

  defp render_app_tab(state, inner_w, target_body_h, fill_screen?, ansi?) do
    app_lines =
      (state.rendered_app_lines || [])
      |> Enum.map(fn line ->
        vis = visible_len(line)

        if vis <= inner_w do
          frame_line(line, vis, inner_w, ansi?)
        else
          plain = strip_ansi(line)
          frame_plain(plain, inner_w, :default, ansi?)
        end
      end)

    controls_rule =
      String.pad_trailing("─── Interactive App Controls & State Bindings ", inner_w, "─")

    control_lines =
      case state.controls do
        [] ->
          [
            frame_plain(
              "  (No interactive Form/Field/Select/Toggle/Button controls in this app — switch to Chat [Tab] to add some!)",
              inner_w,
              :muted,
              ansi?
            )
          ]

        controls ->
          controls
          |> Enum.with_index()
          |> Enum.map(fn {ctrl, idx} ->
            focused? = idx == state.focused_control_idx
            pointer = if focused?, do: "▶ ", else: "  "
            tone = if focused?, do: :active_tab, else: :default

            desc = format_control_summary(ctrl, state.current_ui_state)
            frame_plain("#{pointer}[#{idx + 1}] #{desc}", inner_w, tone, ansi?)
          end)
      end

    ctrl_footer =
      [
        frame_plain("", inner_w, :default, ansi?),
        frame_plain(controls_rule, inner_w, :cyan, ansi?)
      ] ++ control_lines

    fitted_app_lines =
      if fill_screen? do
        Enum.take(app_lines, max(target_body_h - length(ctrl_footer), 4))
      else
        app_lines
      end

    fitted_app_lines ++ ctrl_footer
  end

  # ── 3. SPLIT VIEW TAB (Chat on Left │ Live App on Right) ─────────────────

  defp render_split_tab(state, outer_w, inner_w, target_h, ansi?) do
    if outer_w < 100 do
      # Terminal too narrow for split screen; render Live App with a note
      render_app_tab(state, inner_w, target_h, true, ansi?)
    else
      left_w = max(div(inner_w * 40, 100), 34)
      right_w = max(inner_w - left_w - 3, 40)
      totals = compute_chat_totals(state.current_app)
      live_info = Map.get(state, :live_info, %{active?: false, tick: 0, sources: []})

      chat_hdr_text =
        "─── ◆ Chat (#{totals.turns} turns │ #{format_int(totals.total_tokens)} tok • $#{format_usd(totals.total_cost_usd, 4)} total) "

      left_hdr =
        styled_cell(
          String.pad_trailing(truncate(chat_hdr_text, left_w), left_w, "─"),
          left_w,
          :cyan,
          ansi?
        )

      right_hdr_text =
        if Map.get(live_info, :active?, false) do
          pulse = if rem(Map.get(live_info, :tick, 0), 2) == 0, do: "●", else: "◎"
          srcs = Enum.join(Map.get(live_info, :sources, []), ", ")
          "─── ◆ Live UI [#{pulse} LIVE 1Hz • #{srcs}] "
        else
          "─── ◆ Live UI [Static — ask in Chat to \"make it live\"!] "
        end

      right_hdr =
        styled_cell(
          String.pad_trailing(truncate(right_hdr_text, right_w), right_w, "─"),
          right_w,
          if(Map.get(live_info, :active?, false), do: :green, else: :cyan),
          ansi?
        )

      left_body =
        state
        |> build_chat_column_lines(left_w, ansi?)
        |> Enum.take(-max(target_h - 1, 1))

      left_col = [left_hdr | left_body]

      right_app_lines =
        (state.rendered_app_lines || [])
        |> Enum.map(fn line ->
          vis = visible_len(line)

          if vis <= right_w do
            {line <> String.duplicate(" ", max(right_w - vis, 0)), right_w}
          else
            styled_cell(strip_ansi(line), right_w, :default, ansi?)
          end
        end)

      right_ctrl_lines =
        case state.controls do
          [] ->
            [
              styled_cell(
                "  (No controls yet — ask in Chat to \"make it interactive\"!)",
                right_w,
                :muted,
                ansi?
              )
            ]

          controls ->
            controls
            |> Enum.with_index()
            |> Enum.map(fn {ctrl, idx} ->
              focused? = idx == state.focused_control_idx
              pointer = if focused?, do: "▶ ", else: "  "
              tone = if focused?, do: :active_tab, else: :muted

              styled_cell(
                "#{pointer}[#{idx + 1}] #{format_control_summary(ctrl, state.current_ui_state)}",
                right_w,
                tone,
                ansi?
              )
            end)
        end

      ctrl_hdr =
        styled_cell(
          String.pad_trailing(
            "─── ◆ App Controls (↑/↓ Choose • ←/→ Change • Enter Run) ",
            right_w,
            "─"
          ),
          right_w,
          :cyan,
          ansi?
        )

      ctrl_block = [ctrl_hdr | Enum.take(right_ctrl_lines, 5)]
      app_budget = max(target_h - 1 - length(ctrl_block), 6)

      right_col =
        [right_hdr | Enum.take(right_app_lines, app_budget)] ++ ctrl_block

      max_rows = max(max(length(left_col), length(right_col)), target_h)
      empty_left = {String.duplicate(" ", left_w), left_w}
      empty_right = {String.duplicate(" ", right_w), right_w}
      sep = color(" │ ", :header, ansi?)

      for row_idx <- 0..(max_rows - 1) do
        {l_str, _} = Enum.at(left_col, row_idx, empty_left)
        {r_str, _} = Enum.at(right_col, row_idx, empty_right)
        color("│ ", :header, ansi?) <> l_str <> sep <> r_str <> color(" │", :header, ansi?)
      end
    end
  end

  defp format_control_summary(%{kind: "Select", label: label, var: var, options: opts}, ui_state) do
    cur = Map.get(ui_state, var, List.first(opts) || "")
    opts_preview = Enum.join(Enum.take(opts, 5), " | ")
    "#{label}: ◀ #{cur} ▶  (←/→ options: #{opts_preview})"
  end

  defp format_control_summary(%{kind: "Toggle", label: label, var: var}, ui_state) do
    cur = Map.get(ui_state, var, false)
    mark = if cur in [true, "true", 1], do: "[x] ON", else: "[ ] OFF"
    "#{label}: #{mark}  (←/→ to toggle)"
  end

  defp format_control_summary(%{kind: "Field", label: label, var: var, placeholder: ph}, ui_state) do
    cur = Map.get(ui_state, var, "")
    shown = if cur == "", do: "(empty, default: #{ph})", else: inspect(cur)
    "#{label}: #{shown}"
  end

  defp format_control_summary(
         %{kind: "Button", label: label, has_action?: has_act?},
         _ui_state
       ) do
    act_tag = if has_act?, do: "  (press Enter to ask AI)", else: ""
    "Button: [ #{label} ]#{act_tag}"
  end

  # ── 4. CODE & LIVE DATA PLANE INSPECTOR TAB ([F4:Code]) ──────────────────

  defp render_code_tab(state, inner_w, target_body_h, fill_screen?, ansi?) do
    code = Map.get(state.current_app, "openui_code", "") |> String.trim()
    lines = String.split(code, "\n")

    live_info =
      Map.get(state, :live_info, %{
        active?: false,
        tick: 0,
        sources: [],
        pipelines: [],
        live_bindings: %{}
      })

    meta_line =
      "Loop 1 (LLM Control Plane) — OpenUI Lang DSL (#{length(lines)} statements, #{byte_size(code)} bytes):"

    numbered_lines =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, idx} ->
        num = String.pad_leading(Integer.to_string(idx), 2, " ")
        frame_plain("#{num} │ #{line}", inner_w, :yellow, ansi?)
      end)

    pipelines = Map.get(live_info, :pipelines, [])

    pipeline_lines =
      if pipelines == [] do
        [
          frame_plain(
            "  (No active StreamSource — UI is static. Ask in Chat to \"make it live\"!)",
            inner_w,
            :muted,
            ansi?
          )
        ]
      else
        Enum.map(pipelines, fn p ->
          frame_plain("  • #{p}", inner_w, :green, ansi?)
        end)
      end

    live_bindings = Map.get(live_info, :live_bindings, %{})

    live_pairs =
      live_bindings
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("  │  ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    live_bindings_line =
      if live_pairs == "",
        do: "  Polled $live_* values: (none)",
        else: "  Polled $live_* (tick ##{Map.get(live_info, :tick, 0)}): #{live_pairs}"

    state_pairs =
      state.current_ui_state
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    state_line =
      if state_pairs == "",
        do: "  Interactive $state: (none declared)",
        else: "  Interactive $state: #{state_pairs}"

    footer_block =
      [
        frame_plain(String.duplicate("─", inner_w), inner_w, :muted, ansi?),
        frame_plain(
          "Loop 2 (1Hz Native Elixir Data Plane & Parsers — 0 Gemini calls/tick):",
          inner_w,
          :cyan,
          ansi?
        )
      ] ++
        pipeline_lines ++
        [
          frame_plain(live_bindings_line, inner_w, :info, ansi?),
          frame_plain(state_line, inner_w, :info, ansi?)
        ]

    fitted_code_lines =
      if fill_screen? do
        code_budget = max(target_body_h - 2 - length(footer_block), 4)

        if length(numbered_lines) > code_budget do
          Enum.take(numbered_lines, code_budget - 1) ++
            [
              frame_plain(
                "  … (#{length(numbered_lines) - (code_budget - 1)} more statements in app JSON)",
                inner_w,
                :muted,
                ansi?
              )
            ]
        else
          numbered_lines
        end
      else
        numbered_lines
      end

    [
      frame_plain(meta_line, inner_w, :cyan, ansi?),
      frame_plain(String.duplicate("─", inner_w), inner_w, :muted, ansi?)
    ] ++ fitted_code_lines ++ footer_block
  end

  # ── 5. APPS (CONVERSATIONS) TAB ──────────────────────────────────────────

  defp render_apps_tab(state, inner_w, ansi?) do
    current_id = Map.get(state.current_app, "id")
    title_w = max(inner_w - 58, 18)

    hdr =
      TUIRenderer.fit_cell("#", 3, "left") <>
        " │ " <>
        TUIRenderer.fit_cell("App ID", 18, "left") <>
        " │ " <>
        TUIRenderer.fit_cell("App Title", title_w, "left") <>
        " │ " <>
        TUIRenderer.fit_cell("Rev", 4, "right") <>
        " │ " <>
        TUIRenderer.fit_cell("Turns", 5, "right") <>
        " │ " <>
        TUIRenderer.fit_cell("Tokens ($)", 16, "right")

    rule = String.duplicate("─", inner_w)

    rows =
      state.apps_list
      |> Enum.with_index(1)
      |> Enum.map(fn {app, idx} ->
        active? = app["id"] == current_id
        marker = if active?, do: "★#{idx}", else: " #{idx}"
        totals = compute_chat_totals(app)

        tok_cost_str =
          "#{format_int(totals.total_tokens)} ($#{format_usd(totals.total_cost_usd, 4)})"

        row_str =
          TUIRenderer.fit_cell(marker, 3, "left") <>
            " │ " <>
            TUIRenderer.fit_cell(to_string(app["id"]), 18, "left") <>
            " │ " <>
            TUIRenderer.fit_cell(to_string(app["title"]), title_w, "left") <>
            " │ " <>
            TUIRenderer.fit_cell("v#{app["revision"] || 1}", 4, "right") <>
            " │ " <>
            TUIRenderer.fit_cell(Integer.to_string(totals.turns), 5, "right") <>
            " │ " <>
            TUIRenderer.fit_cell(tok_cost_str, 16, "right")

        tone = if active?, do: :green, else: :default
        frame_plain(row_str, inner_w, tone, ansi?)
      end)

    [
      frame_plain(
        "Every Conversation in OpenUI Studio is a persistent, live-editable App:",
        inner_w,
        :cyan,
        ansi?
      ),
      frame_plain(hdr, inner_w, :bright, ansi?),
      frame_plain(rule, inner_w, :muted, ansi?)
    ] ++
      rows ++
      [
        frame_plain(rule, inner_w, :muted, ansi?),
        frame_plain(
          "Shortcuts: [Ctrl+W] Switch to Next App  │  [Ctrl+N] Create New App  │  [Tab] Return to UI",
          inner_w,
          :info,
          ansi?
        )
      ]
  end

  # ── Bottom Dock (AGY-Style Prompt Composer + Slash Popup + Status Bar) ───

  @slash_commands [
    {"/model <name>", "Switch Gemini model/effort (e.g. /model argon low, /model 3.8-flash)"},
    {"/undo", "Revert UI to previous revision (Ctrl+U)"},
    {"/new <title>", "Create a new UI with its own chat (Ctrl+N)"},
    {"/switch <id>", "Switch active UI conversation (Ctrl+W)"},
    {"/reset", "Reset seeded example apps to clean defaults"},
    {"/split", "Side-by-side AGY Chat + Live UI view (F3)"},
    {"/app", "Fullscreen Live UI view (F2 / Tab)"},
    {"/chat", "Fullscreen AGY Chat view (F1)"},
    {"/code", "Inspect OpenUI-Lang source & AST bindings (F4)"},
    {"/quit", "Exit OpenUI Studio (Ctrl+Q)"}
  ]

  defp render_bottom_dock(state, outer_w, inner_w, ansi?) do
    sep = "├" <> String.duplicate("─", outer_w - 2) <> "┤"
    bot = "╰" <> String.duplicate("─", outer_w - 2) <> "╯"

    prompt_prefix = "❯ "

    {display_str, input_tone} =
      if state.input_buffer == "" do
        {
          "Ask a question, describe a UI change, or type / for commands (try: \"use argon low\")...",
          :muted
        }
      else
        {state.input_buffer <> "█", :bright}
      end

    clipped =
      TUIRenderer.fit_cell(display_str, max(inner_w - String.length(prompt_prefix), 10), "left")

    line_ansi = color(prompt_prefix, :green, ansi?) <> color(clipped, input_tone, ansi?)
    primary_dock_line = frame_line(line_ansi, inner_w, inner_w, ansi?)

    slash_lines = render_slash_autocomplete(state.input_buffer, inner_w, ansi?)

    model_name = Map.get(state, :model, nil) || OpenUITUI.Config.default_model()
    effort = Map.get(state, :reasoning_effort, nil)
    model_badge = OpenUITUI.Config.format_model_badge(model_name, effort)
    totals = compute_chat_totals(state.current_app)

    status_str = state.status_message || "Ready"

    right_meta =
      "◆ #{model_badge} • #{format_int(totals.total_tokens)} tok ($#{format_usd(totals.total_cost_usd, 4)}) │ [Tab] View [↑/↓] Controls [Ctrl+W] App [Ctrl+Q] Quit"

    left_budget = max(inner_w - String.length(right_meta) - 3, 18)
    left_status = TUIRenderer.fit_cell("● #{status_str}", left_budget, "left")
    status_full = left_status <> " │ " <> right_meta

    [color(sep, :header, ansi?)] ++
      slash_lines ++
      [
        primary_dock_line,
        frame_plain(status_full, inner_w, :muted, ansi?),
        color(bot, :header, ansi?)
      ]
  end

  defp render_slash_autocomplete(input_buffer, inner_w, ansi?) when is_binary(input_buffer) do
    trimmed = String.trim_leading(input_buffer)

    if String.starts_with?(trimmed, "/") do
      query = trimmed |> String.split(~r/\s+/, parts: 2) |> List.first() |> String.downcase()

      matches =
        @slash_commands
        |> Enum.filter(fn {cmd, _desc} ->
          cmd_Token = cmd |> String.split(" ") |> List.first()
          String.starts_with?(cmd_Token, query) or query == "/"
        end)
        |> Enum.take(5)

      if matches == [] do
        []
      else
        header =
          frame_plain(
            "╭─ Slash Commands (type & press [Enter]) " <>
              String.duplicate("─", max(inner_w - 43, 2)) <> "╮",
            inner_w,
            :cyan,
            ansi?
          )

        rows =
          Enum.map(matches, fn {cmd, desc} ->
            cmd_col = TUIRenderer.fit_cell(cmd, 16, "left")
            desc_col = TUIRenderer.fit_cell(desc, max(inner_w - 23, 12), "left")

            line_ansi =
              color("│ ", :cyan, ansi?) <>
                color(cmd_col, :bright, ansi?) <>
                color(" │ ", :muted, ansi?) <>
                color(desc_col, :muted, ansi?) <>
                color(" │", :cyan, ansi?)

            frame_line(line_ansi, inner_w, inner_w, ansi?)
          end)

        [header | rows]
      end
    else
      []
    end
  end

  defp render_slash_autocomplete(_, _inner_w, _ansi?), do: []

  @doc """
  Computes cumulative token and `$` cost totals across all messages in an App conversation.
  """
  @spec compute_chat_totals(map() | nil) :: map()
  def compute_chat_totals(nil) do
    %{turns: 0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, total_cost_usd: 0.0}
  end

  def compute_chat_totals(app) when is_map(app) do
    messages = Map.get(app, "messages", [])

    Enum.reduce(
      messages,
      %{turns: 0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, total_cost_usd: 0.0},
      fn msg, acc ->
        role = Map.get(msg, "role", "user")
        meta = Map.get(msg, "meta", %{}) || %{}
        pending? = Map.get(meta, "pending", false) == true

        turns_inc = if role in ["user", "action"], do: 1, else: 0

        if role == "assistant" and not pending? do
          p_tok = parse_num(Map.get(meta, "prompt_tokens", 0)) |> round()
          c_tok = parse_num(Map.get(meta, "completion_tokens", 0)) |> round()
          t_tok = parse_num(Map.get(meta, "total_tokens", p_tok + c_tok)) |> round()
          cost = parse_num(Map.get(meta, "cost_usd", 0.0)) * 1.0

          %{
            acc
            | turns: acc.turns + turns_inc,
              prompt_tokens: acc.prompt_tokens + p_tok,
              completion_tokens: acc.completion_tokens + c_tok,
              total_tokens: acc.total_tokens + t_tok,
              total_cost_usd: acc.total_cost_usd + cost
          }
        else
          %{acc | turns: acc.turns + turns_inc}
        end
      end
    )
  end

  defp parse_num(n) when is_number(n), do: n
  defp parse_num(_), do: 0

  defp format_int(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_int(n), do: to_string(n)

  defp format_usd(val, decimals) when is_number(val) do
    :erlang.float_to_binary(val * 1.0, decimals: decimals)
  end

  defp format_usd(_, decimals), do: :erlang.float_to_binary(0.0, decimals: decimals)

  # ── Viewport Vertical Fitting (Full-Screen Stretching) ───────────────────

  defp fit_vertical_viewport(lines, target_h, inner_w, active_tab, ansi?) do
    count = length(lines)

    cond do
      count == target_h ->
        lines

      count < target_h ->
        pad_count = target_h - count
        blank = frame_plain("", inner_w, :default, ansi?)
        lines ++ List.duplicate(blank, pad_count)

      count > target_h and active_tab == :chat ->
        # Keep the bottom-most recent messages in Chat view
        Enum.take(lines, -target_h)

      count > target_h ->
        # Keep the top-most lines in App/Code/Apps view
        Enum.take(lines, target_h)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp styled_cell(str, width, tone, ansi?) do
    cell = TUIRenderer.fit_cell(to_string(str), width, "left")
    {color(cell, tone, ansi?), width}
  end

  defp frame_plain(str, inner_w, tone, ansi?) do
    cell = TUIRenderer.fit_cell(to_string(str), inner_w, "left")
    color("│ ", :header, ansi?) <> color(cell, tone, ansi?) <> color(" │", :header, ansi?)
  end

  defp frame_line(ansi_str, visible_len, inner_w, ansi?) do
    pad = String.duplicate(" ", max(inner_w - visible_len, 0))
    color("│ ", :header, ansi?) <> ansi_str <> pad <> color(" │", :header, ansi?)
  end

  defp strip_ansi(str), do: String.replace(str, @ansi_regex, "")
  defp visible_len(str), do: str |> strip_ansi() |> String.length()

  defp wrap_text(text, width) when is_binary(text) and width > 10 do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      words = String.split(paragraph, ~r/\s+/, trim: true)

      if words == [] do
        [""]
      else
        words
        |> Enum.reduce({[], ""}, fn word, {lines, current} ->
          cond do
            current == "" ->
              {lines, word}

            String.length(current) + 1 + String.length(word) <= width ->
              {lines, current <> " " <> word}

            true ->
              {[current | lines], word}
          end
        end)
        |> then(fn {lines, last} ->
          Enum.reverse(if last == "", do: lines, else: [last | lines])
        end)
      end
    end)
  end

  defp count_statements(code) when is_binary(code) do
    code
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> length()
  end

  defp truncate(str, max) do
    if String.length(str) > max, do: String.slice(str, 0, max - 1) <> "…", else: str
  end

  defp color(str, _tone, false), do: str
  defp color(str, :default, true), do: str
  defp color(str, :header, true), do: IO.ANSI.cyan() <> str <> IO.ANSI.reset()

  defp color(str, :active_tab, true),
    do: IO.ANSI.bright() <> IO.ANSI.cyan() <> str <> IO.ANSI.reset()

  defp color(str, :bright, true), do: IO.ANSI.bright() <> str <> IO.ANSI.reset()
  defp color(str, :muted, true), do: IO.ANSI.faint() <> str <> IO.ANSI.reset()
  defp color(str, :cyan, true), do: IO.ANSI.cyan() <> str <> IO.ANSI.reset()
  defp color(str, :info, true), do: IO.ANSI.cyan() <> str <> IO.ANSI.reset()
  defp color(str, :green, true), do: IO.ANSI.green() <> str <> IO.ANSI.reset()
  defp color(str, :yellow, true), do: IO.ANSI.yellow() <> str <> IO.ANSI.reset()
end
