defmodule OpenUITUI.TUIRenderer do
  @moduledoc """
  Pure, stateless 80-column Unicode renderer for resolved OpenUI AST nodes.

  Guarantees the 80-column terminal geometry invariant: plain strings are truncated
  and padded by grapheme width (`fit_cell/4`) BEFORE wrapping with ANSI escape
  sequences so invisible ANSI escape bytes never skew column borders.

  Supports:
  - Skeleton nodes (`{:unresolved, var_name}`) with animated Braille spinners (`⠋⠙⠹...`)
  - 8-level vertical Unicode `Sparkline`s (`▁▂▃▄▅▆▇█`)
  - 1/8th fractional horizontal `BarList` / `BarItem` charts (`█▉▊▋▌▍▎▏` + `░`)
  - `Table` with forward-reference guards, exact column budgets, and status cell styling
  - `Panel`, `Dashboard`, `Stack`, `Row`, `Divider`, `KV`, `Form`, `Field`, `Select`, `Toggle`, `Button`
  """

  @outer_width 80
  @inner_width 76

  @spark_ticks {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
  @bar_fractions {"", "▏", "▎", "▍", "▌", "▋", "▊", "▉"}
  @spinner_frames {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

  @type render_opts :: [ansi?: boolean(), tick: non_neg_integer(), width: pos_integer()]

  @doc """
  Renders a resolved OpenUI AST node (or evaluated element map) into a list of
  fixed-width terminal lines (`[String.t()]`).
  """
  @spec render(term(), render_opts()) :: [String.t()]
  def render(ast, opts \\ []) do
    outer_w = Keyword.get(opts, :outer_width, @outer_width)
    frameless? = Keyword.get(opts, :frameless?, false)

    default_inner =
      if frameless? do
        outer_w
      else
        max(outer_w - 4, 20)
      end

    ctx = %{
      ansi?: Keyword.get(opts, :ansi?, true),
      tick: Keyword.get(opts, :tick, 0),
      outer_width: outer_w,
      width: Keyword.get(opts, :width, default_inner),
      frameless?: frameless?,
      hide_forms?: frameless?,
      is_root?: true
    }

    ast
    |> normalize_input()
    |> OpenUITUI.LayoutGuard.clamp(0)
    |> render_node(ctx)
  end

  @doc """
  Renders a resolved OpenUI AST node into a single newline-joined string.
  """
  @spec render_to_string(term(), render_opts()) :: String.t()
  def render_to_string(ast, opts \\ []) do
    render(ast, opts) |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # 1. SKELETON NODES (Unresolved Forward References)
  # ---------------------------------------------------------------------------

  defp render_node({:unresolved, var_name}, ctx) do
    frame = elem(@spinner_frames, rem(ctx.tick, tuple_size(@spinner_frames)))
    label = " #{frame} resolving #{var_name}… "
    inner = fit_cell(label, max(ctx.width - 2, 1), "left")
    line = "[" <> inner <> "]"
    [colorize(line, "muted", ctx.ansi?)]
  end

  # Non-visual live stream declarations produce zero lines
  defp render_node({decl, _args}, _ctx) when decl in ["StreamSource", "Bind"] do
    []
  end

  # ---------------------------------------------------------------------------
  # 2. SPARKLINES & STAT CARDS
  # ---------------------------------------------------------------------------

  defp render_node({"Sparkline", [points | rest]}, ctx) do
    tone = List.first(rest) || "info"
    [render_sparkline_str(points, ctx.width, tone, ctx.ansi?)]
  end

  defp render_node({"Stat", [label, {"Sparkline", _} = spark_node | rest]}, ctx) do
    delta = List.first(rest)
    render_node({"Stat", [label, "", delta, spark_node]}, ctx)
  end

  defp render_node({"Stat", [label, value | rest]}, ctx) do
    {delta, spark_node} = extract_stat_opts(rest)
    card_w = ctx.width
    inner_w = max(card_w - 4, 10)

    top_title = "─ " <> truncate(safe_str(label), inner_w - 2) <> " "
    top_border = "╭" <> String.pad_trailing(top_title, card_w - 2, "─") <> "╮"
    bot_border = "╰" <> String.duplicate("─", card_w - 2) <> "╯"

    val_str = safe_str(value)

    metric_str =
      case delta do
        d when is_binary(d) and d != "" ->
          if val_str == "", do: d, else: "#{val_str} (#{d})"

        d when not is_nil(d) ->
          d_str = safe_str(d)
          if d_str != "" and val_str != "", do: "#{val_str} (#{d_str})", else: val_str

        _ ->
          val_str
      end

    spark_raw =
      case spark_node do
        {"Sparkline", [pts | s_rest]} ->
          tone = safe_str(List.first(s_rest) || "info")
          raw_sparkline(pts, max(inner_w - String.length(metric_str) - 2, 8), tone)

        {:unresolved, _} ->
          {"⋯", "muted"}

        _ ->
          {"", "default"}
      end

    body_line = format_stat_body(metric_str, spark_raw, inner_w, ctx.ansi?)

    [
      top_border,
      "│ " <> body_line <> " │",
      bot_border
    ]
  end

  # ---------------------------------------------------------------------------
  # 3. BARLIST & BARITEM (1/8th Fractional Block Resolution)
  # ---------------------------------------------------------------------------

  defp render_node({"BarList", [items]}, ctx) when is_list(items) do
    resolved_items = Enum.filter(items, &match?({"BarItem", _}, &1))
    max_val = compute_bar_max(resolved_items)

    Enum.flat_map(items, fn
      {"BarItem", [label, val | rest]} when is_number(val) ->
        right_text = List.first(rest) || "#{val}%"
        [render_bar_row(safe_str(label), val, max_val, safe_str(right_text), ctx)]

      {:unresolved, _} = skel ->
        render_node(skel, ctx)

      _other ->
        []
    end)
  end

  defp render_node({"Progress", [label, pct | _]}, ctx) when is_number(pct) do
    [render_bar_row(safe_str(label), pct, 100.0, "#{pct}%", ctx)]
  end

  # ---------------------------------------------------------------------------
  # 4. TABLES (With Forward-Reference Guards & Exact Column Alignment)
  # ---------------------------------------------------------------------------

  defp render_node({"Table", [cols, rows | rest]}, ctx) when is_list(cols) and is_list(rows) do
    if cols == [] or Enum.any?(cols, &match?({:unresolved, _}, &1)) do
      render_node({:unresolved, "table_columns"}, ctx)
    else
      specs = parse_col_specs(cols, ctx.width)
      header_line = render_table_header(specs, ctx)
      rule_line = render_table_rule(specs, ctx.width)
      data_lines = Enum.flat_map(rows, &render_table_row(&1, specs, ctx))
      footer_lines = render_table_footer(List.first(rest), rule_line, ctx)

      [header_line, rule_line | data_lines] ++ footer_lines
    end
  end

  # Support 1-argument columnar Table([Col("Header", ["v1", "v2"]), ...])
  defp render_node({"Table", [cols]}, ctx) when is_list(cols) do
    if cols == [] or Enum.any?(cols, &match?({:unresolved, _}, &1)) do
      render_node({:unresolved, "table_columns"}, ctx)
    else
      case cols do
        [{"Col", [_hdr, data | _]} | _] when is_list(data) ->
          {col_defs, rows} = transpose_columnar_cols(cols)
          render_node({"Table", [col_defs, rows]}, ctx)

        _ ->
          render_node({:unresolved, "table"}, ctx)
      end
    end
  end

  defp render_node({"Table", _incomplete_args}, ctx) do
    render_node({:unresolved, "table"}, ctx)
  end

  # ---------------------------------------------------------------------------
  # 5. FORMS & INTERACTIVE CONTROLS (Form, Field, Select, Toggle, Button)
  # ---------------------------------------------------------------------------

  defp render_node({"Form", [fields, buttons | _]}, ctx)
       when is_list(fields) and is_list(buttons) do
    if Map.get(ctx, :hide_forms?, false) or Map.get(ctx, :frameless?, false) do
      []
    else
      field_lines = Enum.flat_map(fields, &render_node(&1, ctx))

      btn_str =
        buttons
        |> Enum.map(fn
          {"Button", [label | _]} -> "[ #{label} ]"
          other when is_binary(other) -> "[ #{other} ]"
          _ -> "[ Action ]"
        end)
        |> Enum.join("  ")

      btn_line = colorize(fit_cell(btn_str, ctx.width, "left"), "bold", ctx.ansi?)
      field_lines ++ [String.duplicate(" ", ctx.width), btn_line]
    end
  end

  defp render_node({"Field", [label, value | rest]}, ctx) do
    placeholder = List.first(rest) || ""
    secret? = Enum.at(rest, 1) == true
    l_cell = colorize(fit_cell(safe_str(label), 16, "left"), "muted", ctx.ansi?)
    val_str = if safe_str(value) == "", do: safe_str(placeholder), else: safe_str(value)

    val_str =
      if secret? and val_str != "",
        do: String.duplicate("•", String.length(val_str)),
        else: val_str

    box_w = max(ctx.width - 16 - 5, 10)
    v_cell = "[ " <> fit_cell(val_str, box_w, "left") <> " ]"
    [l_cell <> " " <> v_cell]
  end

  defp render_node({"Select", [label, current | _rest]}, ctx) do
    l_cell = colorize(fit_cell(safe_str(label), 16, "left"), "muted", ctx.ansi?)
    sel_str = "◀ #{safe_str(current)} ▶"
    v_cell = colorize(fit_cell(sel_str, max(ctx.width - 17, 10), "left"), "info", ctx.ansi?)
    [l_cell <> " " <> v_cell]
  end

  defp render_node({"Toggle", [label, checked | _]}, ctx) do
    mark = if checked in [true, "true", 1], do: "[x]", else: "[ ]"
    line = fit_cell("#{mark} #{safe_str(label)}", ctx.width, "left")
    [line]
  end

  defp render_node({"Button", [label | _]}, ctx) do
    [colorize(fit_cell("[ #{safe_str(label)} ]", ctx.width, "left"), "bold", ctx.ansi?)]
  end

  # ---------------------------------------------------------------------------
  # 6. CONTAINERS (Panel, Dashboard, Stack, Row, Divider, Text, KV, Alert)
  # ---------------------------------------------------------------------------

  defp render_node({"Dashboard", [title, _subtitle, children | _]}, ctx) when is_list(children) do
    render_node({"Panel", [safe_str(title), children, "info"]}, ctx)
  end

  defp render_node({"Panel", [title, children | rest]}, ctx) when is_list(children) do
    raw_tone = safe_str(List.first(rest) || "info")

    tone =
      case raw_tone do
        "warning" -> "warn"
        "success" -> "ok"
        "default" -> "info"
        other -> other
      end

    normalized_children =
      Enum.map(children, fn
        s when is_binary(s) -> {"Text", ["• " <> s]}
        other -> other
      end)

    if Map.get(ctx, :frameless?, false) do
      child_ctx = %{ctx | frameless?: false, is_root?: false}
      Enum.flat_map(normalized_children, &render_node(&1, child_ctx))
    else
      box_w =
        if Map.get(ctx, :is_root?, false) do
          Map.get(ctx, :outer_width, @outer_width)
        else
          max(ctx.width, 20)
        end

      inner_w = max(box_w - 4, 12)
      inner_ctx = %{ctx | width: inner_w, outer_width: box_w, frameless?: false, is_root?: false}

      title_clean = safe_str(title)

      top_raw =
        if title_clean != "" do
          title_str = "─ ◆ " <> truncate(title_clean, max(box_w - 8, 10)) <> " "
          "╭" <> String.pad_trailing(title_str, box_w - 2, "─") <> "╮"
        else
          "╭" <> String.duplicate("─", box_w - 2) <> "╮"
        end

      bot_raw = "╰" <> String.duplicate("─", box_w - 2) <> "╯"

      body_lines =
        normalized_children
        |> Enum.flat_map(&render_node(&1, inner_ctx))
        |> Enum.map(fn line ->
          colorize("│ ", tone, ctx.ansi?) <> line <> colorize(" │", tone, ctx.ansi?)
        end)

      [colorize(top_raw, tone, ctx.ansi?) | body_lines] ++ [colorize(bot_raw, tone, ctx.ansi?)]
    end
  end

  defp render_node({"Stack", [children | rest]}, ctx) when is_list(children) do
    gap = List.first(rest) || 0
    blank = String.duplicate(" ", ctx.width)

    children
    |> Enum.map(&render_node(&1, ctx))
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse(if(is_integer(gap) and gap > 0, do: [blank], else: []))
    |> List.flatten()
  end

  defp render_node({"Row", [children]}, ctx) when is_list(children) and children != [] do
    count = length(children)
    gap = 2
    col_w = div(ctx.width - gap * (count - 1), count)
    child_ctx = %{ctx | width: col_w, frameless?: false}

    blocks = Enum.map(children, &render_node(&1, child_ctx))
    zip_horizontal_blocks(blocks, col_w, gap, ctx.width)
  end

  defp render_node({"Divider", rest}, ctx) do
    case List.first(rest) do
      label when not is_nil(label) ->
        lbl_str = safe_str(label)

        if lbl_str != "" do
          prefix = "─── " <> truncate(lbl_str, max(ctx.width - 6, 20)) <> " "
          [colorize(String.pad_trailing(prefix, ctx.width, "─"), "info", ctx.ansi?)]
        else
          [colorize(String.duplicate("─", ctx.width), "muted", ctx.ansi?)]
        end

      _ ->
        [colorize(String.duplicate("─", ctx.width), "muted", ctx.ansi?)]
    end
  end

  defp render_node({"KV", [pairs]}, ctx) when is_list(pairs) do
    max_key_len =
      pairs
      |> Enum.map(fn
        [k | _] -> String.length(safe_str(k))
        {k, _} -> String.length(safe_str(k))
        _ -> 12
      end)
      |> Enum.max(fn -> 14 end)

    max_allowed_key_w =
      if ctx.width <= 44 do
        11
      else
        max(min(div(ctx.width * 34, 100), 22), 12)
      end

    min_key_w = if ctx.width <= 44, do: 9, else: 12
    key_w = min(max(max_key_len, min_key_w), max_allowed_key_w)
    val_w = max(ctx.width - key_w - 3, 10)
    sep = colorize(" │ ", "muted", ctx.ansi?)

    Enum.map(pairs, fn
      [k, v | _] ->
        k_cell = colorize(fit_cell(safe_str(k), key_w, "left"), "bold", ctx.ansi?)
        v_cell = fit_cell(safe_str(v), val_w, "left")
        k_cell <> sep <> v_cell

      {k, v} ->
        k_cell = colorize(fit_cell(safe_str(k), key_w, "left"), "bold", ctx.ansi?)
        v_cell = fit_cell(safe_str(v), val_w, "left")
        k_cell <> sep <> v_cell

      _ ->
        String.duplicate(" ", ctx.width)
    end)
  end

  defp render_node({"KeyValue", [entries | _]}, ctx) when is_map(entries) do
    pairs =
      entries
      |> Map.delete("__keys__")
      |> Enum.map(fn {k, v} -> [safe_str(k), safe_str(v)] end)

    render_node({"KV", [pairs]}, ctx)
  end

  defp render_node({"Badge", [label | rest]}, ctx) do
    tone = safe_str(List.first(rest) || "info")
    mapped = if tone == "success", do: "ok", else: if(tone == "warning", do: "warn", else: tone)
    line = fit_cell("[#{safe_str(label)}]", ctx.width, "left")
    [colorize(line, mapped, ctx.ansi?)]
  end

  defp render_node({"Alert", [tone, message | _]}, ctx) do
    tone_str = safe_str(tone)

    {mapped_tone, prefix} =
      case tone_str do
        t when t in ["success", "ok"] -> {"ok", "✔ OK   │ "}
        t when t in ["warning", "warn"] -> {"warn", "▲ WARN │ "}
        "error" -> {"error", "✖ ERR  │ "}
        _ -> {"info", "● INFO │ "}
      end

    line = fit_cell(prefix <> safe_str(message), ctx.width, "left")
    [colorize(line, mapped_tone, ctx.ansi?)]
  end

  defp render_node({"Alert", [message]}, ctx) do
    render_node({"Alert", ["info", message]}, ctx)
  end

  defp render_node({"Text", [content | rest]}, ctx) do
    style = safe_str(List.first(rest) || "body")
    line = fit_cell(safe_str(content), ctx.width, "left")
    [colorize(line, style, ctx.ansi?)]
  end

  defp render_node(str, ctx) when is_binary(str) do
    render_node({"Text", ["• " <> str, "body"]}, ctx)
  end

  defp render_node(_unknown, ctx) do
    [String.duplicate(" ", ctx.width)]
  end

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS: Sparkline Math
  # ---------------------------------------------------------------------------

  defp render_sparkline_str(points, width, tone, ansi?) do
    {raw, resolved_tone} = raw_sparkline(points, width, tone)
    padded = fit_cell(raw, width, "left")
    colorize(padded, resolved_tone, ansi?)
  end

  @doc false
  def raw_sparkline(points, max_len, tone \\ "info")

  def raw_sparkline(points, max_len, tone) when is_list(points) do
    nums = points |> Enum.filter(&is_number/1) |> Enum.take(-max_len)

    case nums do
      [] ->
        {"", tone}

      list ->
        {min_v, max_v} = Enum.min_max(list)
        span = max_v - min_v

        bars =
          Enum.map_join(list, "", fn val ->
            idx =
              if span == 0 do
                3
              else
                round((val - min_v) / span * 7)
              end

            elem(@spark_ticks, min(max(idx, 0), 7))
          end)

        {bars, tone}
    end
  end

  def raw_sparkline(_non_list, _max_len, tone), do: {"", tone}

  defp extract_stat_opts([delta, spark | _]) when is_binary(delta), do: {delta, spark}
  defp extract_stat_opts([{"Sparkline", _} = spark | _]), do: {nil, spark}
  defp extract_stat_opts([{:unresolved, _} = skel | _]), do: {nil, skel}
  defp extract_stat_opts([delta | _]) when is_binary(delta), do: {delta, nil}
  defp extract_stat_opts(_), do: {nil, nil}

  defp format_stat_body(metric_str, {spark_str, spark_tone}, inner_w, ansi?) do
    m_clipped = truncate(metric_str, inner_w)
    m_len = String.length(m_clipped)
    s_len = String.length(spark_str)

    if s_len > 0 and m_len + 1 + s_len <= inner_w do
      gap = String.duplicate(" ", inner_w - m_len - s_len)
      colorize(m_clipped, "bold", ansi?) <> gap <> colorize(spark_str, spark_tone, ansi?)
    else
      colorize(fit_cell(m_clipped, inner_w, "left"), "bold", ansi?)
    end
  end

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS: High-Resolution BarList Math
  # ---------------------------------------------------------------------------

  defp compute_bar_max([]), do: 100.0

  defp compute_bar_max(items) do
    values =
      for {"BarItem", [_label, val | _]} <- items, is_number(val) do
        val
      end

    case values do
      [] -> 100.0
      list -> max(Enum.max(list) * 1.0, 100.0)
    end
  end

  @doc false
  def render_bar_row(label, val, max_val, right_text, ctx) do
    label_w = 16
    right_w = 12
    bar_w = max(ctx.width - label_w - right_w - 4, 10)

    ratio = min(max(val / max(max_val, 1.0e-6), 0.0), 1.0)
    total_eighths = round(ratio * bar_w * 8)
    full_blocks = div(total_eighths, 8)
    remainder = rem(total_eighths, 8)

    fractional = if remainder > 0, do: elem(@bar_fractions, remainder), else: ""
    filled_len = full_blocks + if(remainder > 0, do: 1, else: 0)
    empty_len = max(bar_w - filled_len, 0)

    filled_str = String.duplicate("█", full_blocks) <> fractional
    track_str = String.duplicate("░", empty_len)

    l_cell = fit_cell(label, label_w, "left")
    r_cell = fit_cell(right_text, right_w, "right")

    colored_bar =
      colorize(filled_str, "info", ctx.ansi?) <> colorize(track_str, "muted", ctx.ansi?)

    l_cell <> "  " <> colored_bar <> "  " <> r_cell
  end

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS: Table Alignment & Framing
  # ---------------------------------------------------------------------------

  defp parse_col_specs(cols, total_width) do
    count = max(length(cols), 1)
    sep_cost = max(count - 1, 0) * 3
    avail = max(total_width - sep_cost, count * 6)
    default_w = max(div(avail - 2, count), 8)

    raw_specs =
      Enum.map(cols, fn
        {"Col", [hdr, width, align | _]} when is_integer(width) ->
          %{header: safe_str(hdr), width: width, align: safe_str(align)}

        {"Col", [hdr, width]} when is_integer(width) ->
          %{header: safe_str(hdr), width: width, align: "left"}

        {"Col", [hdr | _]} ->
          %{header: safe_str(hdr), width: default_w, align: "left"}

        _ ->
          %{header: "Col", width: 12, align: "left"}
      end)

    raw_sum = Enum.reduce(raw_specs, 0, &(&1.width + &2))

    # In wide viewports (> 76 cols), stretch columns proportionally to fill the table width
    if total_width > @inner_width and raw_sum > 0 and raw_sum < avail do
      scale = avail / raw_sum

      Enum.map(raw_specs, fn s ->
        %{s | width: max(trunc(s.width * scale), s.width)}
      end)
    else
      raw_specs
    end
  end

  defp transpose_columnar_cols(cols) do
    col_defs =
      Enum.map(cols, fn
        {"Col", [hdr | _]} -> {"Col", [safe_str(hdr), 16, "left"]}
        _ -> {"Col", ["Col", 14, "left"]}
      end)

    col_data =
      Enum.map(cols, fn
        {"Col", [_hdr, data | _]} when is_list(data) -> Enum.map(data, &safe_str/1)
        _ -> []
      end)

    max_rows = col_data |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    rows =
      if max_rows == 0 do
        []
      else
        for r <- 0..(max_rows - 1) do
          Enum.map(col_data, fn c -> Enum.at(c, r, "") end)
        end
      end

    {col_defs, rows}
  end

  defp render_table_header(specs, ctx) do
    joined =
      specs
      |> Enum.map_join(" │ ", fn spec ->
        cell = fit_cell(spec.header, spec.width, spec.align)
        colorize(cell, "bold", ctx.ansi?)
      end)

    pad_table_line(joined, specs, ctx.width)
  end

  defp render_table_rule(specs, total_width) do
    rule =
      Enum.map_join(specs, "─┼─", fn spec ->
        String.duplicate("─", spec.width)
      end)

    fit_cell(rule, total_width, "left", "─")
  end

  defp render_table_row({:unresolved, _} = skel, _specs, ctx), do: render_node(skel, ctx)

  defp render_table_row(row, specs, ctx) when is_list(row) do
    joined =
      specs
      |> Enum.with_index()
      |> Enum.map_join(" │ ", fn {spec, idx} ->
        raw_val = row |> Enum.at(idx, "") |> safe_str()
        cell = fit_cell(raw_val, spec.width, spec.align)
        style_table_cell(raw_val, cell, ctx.ansi?)
      end)

    [pad_table_line(joined, specs, ctx.width)]
  end

  defp render_table_row(_invalid, _specs, _ctx), do: []

  defp render_table_footer(footer, rule_line, ctx) when is_binary(footer) and footer != "" do
    [
      rule_line,
      colorize(fit_cell(footer, ctx.width, "right"), "muted", ctx.ansi?)
    ]
  end

  defp render_table_footer(_, _rule_line, _ctx), do: []

  defp pad_table_line(ansi_line, specs, target_width) do
    visible_len =
      Enum.reduce(specs, 0, fn spec, acc -> acc + spec.width end) +
        max(length(specs) - 1, 0) * 3

    trailing = max(target_width - visible_len, 0)
    ansi_line <> String.duplicate(" ", trailing)
  end

  defp style_table_cell(raw, padded, true) when raw in ["healthy", "ok", "OK", "online"] do
    colorize(padded, "ok", true)
  end

  defp style_table_cell(raw, padded, true) when raw in ["degraded", "warn", "WARN", "pending"] do
    colorize(padded, "warn", true)
  end

  defp style_table_cell(raw, padded, true) when raw in ["down", "error", "ERROR", "failed"] do
    colorize(padded, "error", true)
  end

  defp style_table_cell(_raw, padded, _ansi?), do: padded

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS: Horizontal Block Zipping & String Fitting
  # ---------------------------------------------------------------------------

  defp zip_horizontal_blocks(blocks, col_w, gap, total_w) do
    max_height = blocks |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    empty_col = String.duplicate(" ", col_w)
    sep = String.duplicate(" ", gap)
    used_w = length(blocks) * col_w + max(length(blocks) - 1, 0) * gap
    right_pad = String.duplicate(" ", max(total_w - used_w, 0))

    if max_height == 0 do
      []
    else
      for row_idx <- 0..(max_height - 1) do
        row_str =
          Enum.map_join(blocks, sep, fn block ->
            Enum.at(block, row_idx, empty_col)
          end)

        row_str <> right_pad
      end
    end
  end

  @doc """
  Truncates with `…` and pads a plain string to `width` graphemes BEFORE ANSI wrapping.
  """
  @spec fit_cell(String.t(), pos_integer(), String.t(), String.t()) :: String.t()
  def fit_cell(str, width, align \\ "left", pad_char \\ " ") when width > 0 do
    clipped = truncate(str, width)

    case align do
      "right" -> String.pad_leading(clipped, width, pad_char)
      _ -> String.pad_trailing(clipped, width, pad_char)
    end
  end

  defp truncate(str, max_len) when max_len <= 1, do: String.slice(str, 0, max(max_len, 0))

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 1) <> "…"
    else
      str
    end
  end

  defp colorize(str, _tone, false), do: str
  defp colorize(str, "default", true), do: str
  defp colorize(str, "body", true), do: str
  defp colorize(str, "bold", true), do: IO.ANSI.bright() <> str <> IO.ANSI.reset()
  defp colorize(str, "muted", true), do: IO.ANSI.faint() <> str <> IO.ANSI.reset()
  defp colorize(str, "info", true), do: IO.ANSI.cyan() <> str <> IO.ANSI.reset()
  defp colorize(str, "ok", true), do: IO.ANSI.green() <> str <> IO.ANSI.reset()
  defp colorize(str, "warn", true), do: IO.ANSI.yellow() <> str <> IO.ANSI.reset()
  defp colorize(str, "error", true), do: IO.ANSI.red() <> str <> IO.ANSI.reset()
  defp colorize(str, "code", true), do: IO.ANSI.magenta() <> str <> IO.ANSI.reset()
  defp colorize(str, _unknown, true), do: str

  # Converts evaluated OpenUILang element maps (%{"type" => ..., "props" => ...})
  # into tuple AST nodes so `TUIRenderer` can render both representations seamlessly.
  defp normalize_input(%{"type" => "Dashboard", "props" => p}) do
    children = Map.get(p, "children", []) |> Enum.map(&normalize_input/1)
    {"Dashboard", [Map.get(p, "title", "Dashboard"), Map.get(p, "subtitle", ""), children]}
  end

  defp normalize_input(%{"type" => "Panel", "props" => p}) do
    items = Map.get(p, "children") || Map.get(p, "items", [])
    tone = Map.get(p, "tone", "default")
    {"Panel", [Map.get(p, "title", "Panel"), Enum.map(items, &normalize_input/1), tone]}
  end

  defp normalize_input(%{"type" => "Stack", "props" => p}) do
    children = Map.get(p, "children", []) |> Enum.map(&normalize_input/1)
    {"Stack", [children, Map.get(p, "gap", 0)]}
  end

  defp normalize_input(%{"type" => "Row", "props" => p}) do
    children = Map.get(p, "children", []) |> Enum.map(&normalize_input/1)
    {"Row", [children]}
  end

  defp normalize_input(%{"type" => "Stat", "props" => p}) do
    spark = Map.get(p, "spark") |> normalize_input()

    {"Stat",
     [
       Map.get(p, "label", ""),
       Map.get(p, "value", ""),
       Map.get(p, "hint") || Map.get(p, "delta"),
       spark
     ]}
  end

  defp normalize_input(%{"type" => "Sparkline", "props" => p}) do
    {"Sparkline", [Map.get(p, "points", []), Map.get(p, "tone", "info")]}
  end

  defp normalize_input(%{"type" => "BarList", "props" => p}) do
    items = Map.get(p, "items", []) |> Enum.map(&normalize_input/1)
    {"BarList", [items]}
  end

  defp normalize_input(%{"type" => "BarItem", "props" => p}) do
    {"BarItem", [Map.get(p, "label", ""), Map.get(p, "value", 0), Map.get(p, "text")]}
  end

  defp normalize_input(%{"type" => "Progress", "props" => p}) do
    {"Progress", [Map.get(p, "label", ""), Map.get(p, "percent", 0)]}
  end

  defp normalize_input(%{"type" => "Alert", "props" => p}) do
    {"Alert", [Map.get(p, "tone", "info"), Map.get(p, "message", "")]}
  end

  defp normalize_input(%{"type" => "Divider", "props" => p}) do
    {"Divider", [Map.get(p, "label")]}
  end

  defp normalize_input(%{"type" => "KV", "props" => p}) do
    {"KV", [Map.get(p, "pairs", [])]}
  end

  defp normalize_input(%{"type" => "Table", "props" => p}) do
    cols = Map.get(p, "columns") || Map.get(p, "cols", [])
    rows = Map.get(p, "rows")
    footer = Map.get(p, "footer")

    norm_cols = Enum.map(cols, &normalize_input/1)

    if is_list(rows) do
      {"Table", [norm_cols, rows, footer]}
    else
      {"Table", [norm_cols]}
    end
  end

  defp normalize_input(%{"type" => "Col", "props" => p}) do
    hdr = Map.get(p, "header") || Map.get(p, "label", "Col")
    w_or_data = Map.get(p, "width") || Map.get(p, "data", 14)
    align = Map.get(p, "align", "left")
    {"Col", [hdr, w_or_data, align]}
  end

  defp normalize_input(%{"type" => "Form", "props" => p}) do
    fields = Map.get(p, "fields", []) |> Enum.map(&normalize_input/1)
    buttons = Map.get(p, "buttons", []) |> Enum.map(&normalize_input/1)
    {"Form", [fields, buttons]}
  end

  defp normalize_input(%{"type" => "Field", "props" => p}) do
    {"Field",
     [
       Map.get(p, "label", ""),
       Map.get(p, "binding", ""),
       Map.get(p, "placeholder", ""),
       Map.get(p, "secret", false)
     ]}
  end

  defp normalize_input(%{"type" => "Select", "props" => p}) do
    {"Select", [Map.get(p, "label", ""), Map.get(p, "binding", ""), Map.get(p, "options", [])]}
  end

  defp normalize_input(%{"type" => "Toggle", "props" => p}) do
    {"Toggle", [Map.get(p, "label", ""), Map.get(p, "binding", false)]}
  end

  defp normalize_input(%{"type" => "Button", "props" => p}) do
    {"Button", [Map.get(p, "label", "Action")]}
  end

  defp normalize_input(%{"type" => "Text", "props" => p}) do
    {"Text", [Map.get(p, "content") || Map.get(p, "text", ""), Map.get(p, "style", "body")]}
  end

  defp normalize_input(other), do: other

  defp safe_str(nil), do: ""
  defp safe_str(v) when is_binary(v), do: v
  defp safe_str(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp safe_str({:unresolved, ref}), do: "⋯ #{ref}"
  defp safe_str({"Badge", [lbl | _]}), do: "[#{safe_str(lbl)}]"

  defp safe_str({"Sparkline", [pts | rest]}) do
    {bars, _} = raw_sparkline(pts, 12, safe_str(List.first(rest) || "info"))
    bars
  end

  defp safe_str({comp, [first | _]}) when is_binary(comp), do: safe_str(first)
  defp safe_str(list) when is_list(list), do: Enum.map_join(list, ", ", &safe_str/1)
  defp safe_str(other), do: inspect(other)
end
