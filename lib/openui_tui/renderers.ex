defmodule OpenUITUI.Renderers do
  @moduledoc """
  Multi-engine Elixir TUI renderer suite for evaluated `OpenUILang` component trees.

  Supports 4 distinct Elixir rendering backends for side-by-side comparison:
  1. `:pure_ansi` (`OpenUITUI.Renderers.PureANSI`) — Zero-dependency `IO.ANSI` + Unicode box-drawing.
  2. `:owl` (`OpenUITUI.Renderers.OwlRenderer`) — Rich `Owl.Box`, `Owl.Table`, `Owl.ProgressBar`, `Owl.Data`.
  3. `:table_rex` (`OpenUITUI.Renderers.TableRexRenderer`) — `TableRex` ASCII/Unicode tabular engine + ANSI cards.
  4. `:compact_ops` (`OpenUITUI.Renderers.CompactOpsRenderer`) — High-density DevOps/SRE single-screen strip layout.
  """

  alias OpenUITUI.Renderers.{CompactOpsRenderer, OwlRenderer, PureANSI, TableRexRenderer}
  alias OpenUITUI.TUIRenderer

  @type renderer_id :: :fixed_80 | :pure_ansi | :owl | :table_rex | :compact_ops

  @spec available_renderers() :: [renderer_id()]
  def available_renderers, do: [:fixed_80, :pure_ansi, :owl, :table_rex, :compact_ops]

  @doc """
  Renders an evaluated OpenUI Lang root element tree using the specified `renderer`
  and emits `[:openui_tui, :renderer, :render]` telemetry.
  """
  @spec render(map() | tuple() | nil, renderer_id() | String.t()) :: String.t()
  def render(nil, _renderer), do: "(empty OpenUI root)"

  def render(root, renderer) when is_binary(renderer) do
    case renderer do
      "fixed_80" -> render(root, :fixed_80)
      "pure_ansi" -> render(root, :pure_ansi)
      "owl" -> render(root, :owl)
      "table_rex" -> render(root, :table_rex)
      "compact_ops" -> render(root, :compact_ops)
      _ -> render(root, :owl)
    end
  end

  def render(root, renderer) when (is_map(root) or is_tuple(root)) and is_atom(renderer) do
    t0 = System.monotonic_time(:microsecond)

    output =
      case renderer do
        :fixed_80 -> TUIRenderer.render_to_string(root)
        :pure_ansi -> PureANSI.render_node(root)
        :owl -> OwlRenderer.render_node(root)
        :table_rex -> TableRexRenderer.render_node(root)
        :compact_ops -> CompactOpsRenderer.render_node(root)
        _ -> OwlRenderer.render_node(root)
      end

    duration_us = System.monotonic_time(:microsecond) - t0
    byte_len = byte_size(output)
    line_count = length(String.split(output, "\n"))

    root_type =
      cond do
        is_map(root) -> Map.get(root, "type", "unknown")
        is_tuple(root) and tuple_size(root) >= 1 -> to_string(elem(root, 0))
        true -> "unknown"
      end

    :telemetry.execute(
      [:openui_tui, :renderer, :render],
      %{
        duration_us: duration_us,
        output_bytes: byte_len,
        line_count: line_count
      },
      %{
        renderer: Atom.to_string(renderer),
        root_type: root_type
      }
    )

    output
  end

  @doc """
  Renders the same evaluated OpenUI tree across all 4 Elixir TUI engines and returns
  both their rendered outputs and quantitative comparison metrics (render microseconds,
  byte size, line count).
  """
  @spec compare_all(map()) :: map()
  def compare_all(root) when is_map(root) do
    Map.new(available_renderers(), fn r ->
      t0 = System.monotonic_time(:microsecond)
      out = render(root, r)
      duration_us = System.monotonic_time(:microsecond) - t0

      {r,
       %{
         renderer: r,
         output: out,
         duration_us: duration_us,
         output_bytes: byte_size(out),
         line_count: length(String.split(out, "\n"))
       }}
    end)
  end

  @doc """
  Converts an OpenUI `Table` component's columnar `columns` prop (`[%{"type" => "Col", "props" => %{"label" => ..., "data" => [...]}}]`)
  into `{headers, rows}`.
  """
  @spec extract_table(map()) :: {[String.t()], [[String.t()]]}
  def extract_table(props) when is_map(props) do
    cols =
      props
      |> Map.get("columns", [])
      |> Enum.filter(&is_map/1)

    headers =
      Enum.map(cols, fn col ->
        get_in(col, ["props", "label"]) || "Col"
      end)

    col_data =
      Enum.map(cols, fn col ->
        data = get_in(col, ["props", "data"]) || []
        if is_list(data), do: Enum.map(data, &format_cell/1), else: [format_cell(data)]
      end)

    max_rows =
      case Enum.map(col_data, &length/1) do
        [] -> 0
        lengths -> Enum.max(lengths)
      end

    rows =
      if max_rows == 0 do
        []
      else
        for r <- 0..(max_rows - 1) do
          Enum.map(col_data, fn c -> Enum.at(c, r, "") end)
        end
      end

    {headers, rows}
  end

  defp format_cell(nil), do: "-"
  defp format_cell(v) when is_binary(v), do: v
  defp format_cell(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp format_cell(v), do: inspect(v)
end

defmodule OpenUITUI.Renderers.PureANSI do
  @moduledoc """
  Renderer 1: Zero-dependency Pure `IO.ANSI` + Unicode box-drawing renderer.
  Fastest streaming renderer (~15-30µs per frame).
  """

  alias OpenUITUI.Renderers

  def render_node(%{"type" => "Dashboard", "props" => p}) do
    title = Map.get(p, "title", "Dashboard")
    subtitle = Map.get(p, "subtitle", "")
    children = Map.get(p, "children", []) |> Enum.map(&render_node/1) |> Enum.reject(&(&1 == ""))

    header =
      IO.ANSI.cyan() <>
        IO.ANSI.bright() <>
        "╭──────────────────────────────────────────────────────────────────────────╮\n" <>
        "│ ⚡ #{String.pad_trailing(title, 70)} │\n" <>
        if(subtitle != "",
          do:
            "│   " <>
              IO.ANSI.reset() <>
              IO.ANSI.faint() <>
              String.pad_trailing(subtitle, 70) <>
              IO.ANSI.reset() <> IO.ANSI.cyan() <> IO.ANSI.bright() <> " │\n",
          else: ""
        ) <>
        "╰──────────────────────────────────────────────────────────────────────────╯" <>
        IO.ANSI.reset()

    Enum.join([header | children], "\n")
  end

  def render_node(%{"type" => "Stack", "props" => p}) do
    Map.get(p, "children", [])
    |> Enum.map(&render_node/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def render_node(%{"type" => "Row", "props" => p}) do
    items =
      Map.get(p, "children", [])
      |> Enum.map(&render_node/1)
      |> Enum.reject(&(&1 == ""))

    "  " <> Enum.join(items, "   │   ")
  end

  def render_node(%{"type" => "Stat", "props" => p}) do
    label = Map.get(p, "label", "")
    value = Map.get(p, "value", "")
    hint = Map.get(p, "hint")

    hint_str =
      if is_binary(hint) and hint != "" do
        " #{IO.ANSI.faint()}(#{hint})#{IO.ANSI.reset()}"
      else
        ""
      end

    "#{IO.ANSI.faint()}#{label}:#{IO.ANSI.reset()} #{IO.ANSI.bright()}#{IO.ANSI.green()}#{value}#{IO.ANSI.reset()}#{hint_str}"
  end

  def render_node(%{"type" => "Alert", "props" => p}) do
    tone = Map.get(p, "tone", "info")
    msg = Map.get(p, "message", "")

    {color, icon} =
      case tone do
        "error" -> {IO.ANSI.red(), "✖ ERROR"}
        "warning" -> {IO.ANSI.yellow(), "⚠ WARN"}
        "success" -> {IO.ANSI.green(), "✔ OK"}
        _ -> {IO.ANSI.blue(), "ℹ INFO"}
      end

    "  #{color}#{IO.ANSI.bright()}[#{icon}]#{IO.ANSI.reset()} #{msg}"
  end

  def render_node(%{"type" => "Progress", "props" => p}) do
    label = Map.get(p, "label", "Progress")
    pct = (Map.get(p, "percent", 0) || 0) |> max(0) |> min(100)
    width = 28
    filled = round(pct / 100 * width)
    empty = max(width - filled, 0)

    color =
      cond do
        pct >= 85 -> IO.ANSI.red()
        pct >= 65 -> IO.ANSI.yellow()
        true -> IO.ANSI.green()
      end

    bar =
      color <>
        String.duplicate("█", filled) <>
        IO.ANSI.faint() <> String.duplicate("░", empty) <> IO.ANSI.reset()

    "  #{String.pad_trailing(to_string(label), 28)} [#{bar}] #{pct}%"
  end

  def render_node(%{"type" => "Table", "props" => p}) do
    {headers, rows} = Renderers.extract_table(p)

    if headers == [] do
      ""
    else
      widths =
        Enum.with_index(headers)
        |> Enum.map(fn {h, idx} ->
          row_max =
            rows
            |> Enum.map(fn r -> String.length(Enum.at(r, idx, "")) end)
            |> Enum.max(fn -> 0 end)

          max(String.length(h), row_max) + 2
        end)

      top = "  ┌" <> Enum.map_join(widths, "┬", &String.duplicate("─", &1)) <> "┐"

      hdr =
        "  │" <>
          (Enum.zip(headers, widths)
           |> Enum.map_join("│", fn {h, w} ->
             IO.ANSI.bright() <> " " <> String.pad_trailing(h, w - 1) <> IO.ANSI.reset()
           end)) <> "│"

      sep = "  ├" <> Enum.map_join(widths, "┼", &String.duplicate("─", &1)) <> "┤"

      body =
        Enum.map_join(rows, "\n", fn r ->
          "  │" <>
            (Enum.zip(r, widths)
             |> Enum.map_join("│", fn {c, w} -> " " <> String.pad_trailing(c, w - 1) end)) <>
            "│"
        end)

      bot = "  └" <> Enum.map_join(widths, "┴", &String.duplicate("─", &1)) <> "┘"
      Enum.join([top, hdr, sep, body, bot], "\n")
    end
  end

  def render_node(%{"type" => "Panel", "props" => p}) do
    title = Map.get(p, "title", "Panel")
    items = Map.get(p, "items") || Map.get(p, "children", [])

    bullets =
      Enum.map_join(items, "\n", fn
        item when is_map(item) -> render_node(item)
        item -> "    #{IO.ANSI.cyan()}•#{IO.ANSI.reset()} #{inspect_or_str(item)}"
      end)

    "  #{IO.ANSI.bright()}#{IO.ANSI.underline()}#{title}#{IO.ANSI.reset()}\n#{bullets}"
  end

  def render_node(%{"type" => "Badge", "props" => p}) do
    label = Map.get(p, "label", "")
    tone = Map.get(p, "tone", "info")
    color = if tone == "error", do: IO.ANSI.red(), else: IO.ANSI.cyan()
    "#{color}[#{label}]#{IO.ANSI.reset()}"
  end

  def render_node(%{"type" => "KeyValue", "props" => p}) do
    entries = Map.get(p, "entries", %{}) |> Map.delete("__keys__")

    Enum.map_join(entries, "\n", fn {k, v} ->
      "  #{IO.ANSI.faint()}#{k}:#{IO.ANSI.reset()} #{v}"
    end)
  end

  def render_node(%{"type" => "Text", "props" => p}) do
    "  " <> to_string(Map.get(p, "text", ""))
  end

  def render_node(%{"type" => "Button", "props" => p}) do
    label = Map.get(p, "label", "Action")
    cmd = Map.get(p, "command")
    cmd_str = if is_binary(cmd) and cmd != "", do: " -> `#{cmd}`", else: ""
    "  #{IO.ANSI.inverse()} [ #{label} ] #{IO.ANSI.reset()}#{cmd_str}"
  end

  def render_node(_), do: ""

  defp inspect_or_str(v) when is_binary(v), do: v
  defp inspect_or_str(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp inspect_or_str(v), do: inspect(v)
end

defmodule OpenUITUI.Renderers.OwlRenderer do
  @moduledoc """
  Renderer 2: Rich `Owl` toolkit renderer (`Owl.Box`, `Owl.Table`, `Owl.ProgressBar`, `Owl.Data`).
  """

  alias OpenUITUI.Renderers

  def render_node(node) do
    node
    |> render_owl()
    |> to_ansi()
  end

  defp render_owl(%{"type" => "Dashboard", "props" => p}) do
    title = Map.get(p, "title", "Dashboard")
    subtitle = Map.get(p, "subtitle", "")
    children = Map.get(p, "children", []) |> Enum.map(&render_owl/1) |> Enum.reject(&(&1 == ""))

    body_items =
      if subtitle != "" do
        [Owl.Data.tag(subtitle, :faint) | children]
      else
        children
      end

    Owl.Box.new(Enum.intersperse(body_items, "\n"),
      title: Owl.Data.tag(" #{title} ", [:bright, :cyan]),
      border_style: :solid_rounded,
      padding_x: 1
    )
  end

  defp render_owl(%{"type" => "Stack", "props" => p}) do
    Map.get(p, "children", [])
    |> Enum.map(&render_owl/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.intersperse("\n")
  end

  defp render_owl(%{"type" => "Row", "props" => p}) do
    Map.get(p, "children", [])
    |> Enum.map(&render_owl/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.intersperse("  ┃  ")
  end

  defp render_owl(%{"type" => "Stat", "props" => p}) do
    label = Map.get(p, "label", "")
    value = Map.get(p, "value", "")
    hint = Map.get(p, "hint")

    tagged = [
      Owl.Data.tag("#{label}: ", :faint),
      Owl.Data.tag(to_string(value), [:bright, :green])
    ]

    if is_binary(hint) and hint != "" do
      tagged ++ [Owl.Data.tag(" (#{hint})", :faint)]
    else
      tagged
    end
  end

  defp render_owl(%{"type" => "Alert", "props" => p}) do
    tone = Map.get(p, "tone", "info")
    msg = Map.get(p, "message", "")

    color =
      case tone do
        "error" -> :red
        "warning" -> :yellow
        "success" -> :green
        _ -> :cyan
      end

    Owl.Box.new(Owl.Data.tag(msg, color),
      title: Owl.Data.tag(" #{String.upcase(tone)} ", [:bright, color]),
      border_style: :solid,
      padding_x: 1
    )
  end

  defp render_owl(%{"type" => "Progress", "props" => p}) do
    label = to_string(Map.get(p, "label", "Progress"))
    pct = (Map.get(p, "percent", 0) || 0) |> max(0) |> min(100) |> round()
    width = 28
    filled = round(pct / 100 * width)
    empty = max(width - filled, 0)

    [
      Owl.Data.tag(String.pad_trailing(label, 28), :cyan),
      " [",
      Owl.Data.tag(String.duplicate("█", filled), :green),
      Owl.Data.tag(String.duplicate("░", empty), :faint),
      "] #{pct}%"
    ]
  end

  defp render_owl(%{"type" => "Table", "props" => p}) do
    {headers, rows} = Renderers.extract_table(p)

    if headers == [] or rows == [] do
      ""
    else
      maps =
        Enum.map(rows, fn row ->
          Enum.zip(headers, row) |> Map.new()
        end)

      Owl.Table.new(maps)
    end
  end

  defp render_owl(%{"type" => "Panel", "props" => p}) do
    title = Map.get(p, "title", "Panel")
    items = Map.get(p, "items") || Map.get(p, "children", [])

    content =
      items
      |> Enum.map(fn
        i when is_map(i) -> render_owl(i)
        i when is_binary(i) -> "• #{i}"
        i -> "• #{inspect(i)}"
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.intersperse("\n")

    Owl.Box.new(content,
      title: Owl.Data.tag(" #{title} ", :yellow),
      border_style: :solid_rounded,
      padding_x: 1
    )
  end

  defp render_owl(%{"type" => "Badge", "props" => p}) do
    label = Map.get(p, "label", "")
    Owl.Data.tag("[#{label}]", [:bright, :cyan])
  end

  defp render_owl(%{"type" => "KeyValue", "props" => p}) do
    entries = Map.get(p, "entries", %{}) |> Map.delete("__keys__")

    entries
    |> Enum.map(fn {k, v} -> [Owl.Data.tag("#{k}: ", :faint), to_string(v)] end)
    |> Enum.intersperse("\n")
  end

  defp render_owl(%{"type" => "Text", "props" => p}) do
    to_string(Map.get(p, "text", ""))
  end

  defp render_owl(%{"type" => "Button", "props" => p}) do
    label = Map.get(p, "label", "Action")
    Owl.Data.tag(" [ #{label} ] ", [:inverse, :bright])
  end

  defp render_owl(_), do: ""

  defp to_ansi(data) do
    data
    |> Owl.Data.to_chardata()
    |> IO.iodata_to_binary()
  end
end

defmodule OpenUITUI.Renderers.TableRexRenderer do
  @moduledoc """
  Renderer 3: `TableRex` ASCII/Unicode tabular engine combined with structured headers.
  Excels at multi-column alignment and copy-pasteable operational tables.
  """

  alias OpenUITUI.Renderers

  def render_node(%{"type" => "Dashboard", "props" => p}) do
    title = Map.get(p, "title", "Dashboard")
    subtitle = Map.get(p, "subtitle", "")
    children = Map.get(p, "children", []) |> Enum.map(&render_node/1) |> Enum.reject(&(&1 == ""))

    banner =
      TableRex.quick_render!([[subtitle]], [title])
      |> String.trim_trailing()

    Enum.join([banner | children], "\n")
  end

  def render_node(%{"type" => "Stack", "props" => p}) do
    Map.get(p, "children", [])
    |> Enum.map(&render_node/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def render_node(%{"type" => "Row", "props" => p}) do
    children = Map.get(p, "children", [])

    headers =
      Enum.map(children, fn c ->
        get_in(c, ["props", "label"]) || Map.get(c, "type", "Item")
      end)

    vals =
      Enum.map(children, fn c ->
        val = get_in(c, ["props", "value"]) || get_in(c, ["props", "label"]) || ""
        hint = get_in(c, ["props", "hint"])
        if is_binary(hint) and hint != "", do: "#{val} (#{hint})", else: to_string(val)
      end)

    if headers == [] do
      ""
    else
      TableRex.quick_render!([vals], headers) |> String.trim_trailing()
    end
  end

  def render_node(%{"type" => "Table", "props" => p}) do
    {headers, rows} = Renderers.extract_table(p)

    if headers == [] do
      ""
    else
      TableRex.quick_render!(rows, headers) |> String.trim_trailing()
    end
  end

  def render_node(%{"type" => "Panel", "props" => p}) do
    title = Map.get(p, "title", "Panel")

    items =
      (Map.get(p, "items") || Map.get(p, "children", []))
      |> Enum.map(fn
        i when is_binary(i) -> [i]
        i when is_map(i) -> [render_node(i)]
        i -> [inspect(i)]
      end)

    if items == [] do
      ""
    else
      TableRex.quick_render!(items, [title]) |> String.trim_trailing()
    end
  end

  def render_node(other) do
    OpenUITUI.Renderers.PureANSI.render_node(other)
  end
end

defmodule OpenUITUI.Renderers.CompactOpsRenderer do
  @moduledoc """
  Renderer 4: Ultra-dense single-screen DevOps/SRE strip renderer.
  Minimizes vertical lines so complex dashboards fit in compact split panes.
  """

  alias OpenUITUI.Renderers

  def render_node(%{"type" => "Dashboard", "props" => p}) do
    title = Map.get(p, "title", "Dashboard")
    subtitle = Map.get(p, "subtitle", "")
    children = Map.get(p, "children", []) |> Enum.map(&render_node/1) |> Enum.reject(&(&1 == ""))

    hdr =
      "#{IO.ANSI.bright()}#{IO.ANSI.cyan()}══ #{title}#{IO.ANSI.reset()} #{IO.ANSI.faint()}[#{subtitle}]#{IO.ANSI.reset()}"

    Enum.join([hdr | children], "\n")
  end

  def render_node(%{"type" => "Stack", "props" => p}) do
    Map.get(p, "children", [])
    |> Enum.map(&render_node/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def render_node(%{"type" => "Row", "props" => p}) do
    items =
      Map.get(p, "children", [])
      |> Enum.map(&render_node/1)
      |> Enum.reject(&(&1 == ""))

    "▸ " <> Enum.join(items, " · ")
  end

  def render_node(%{"type" => "Stat", "props" => p}) do
    label = Map.get(p, "label", "")
    value = Map.get(p, "value", "")
    "#{label}=#{IO.ANSI.bright()}#{value}#{IO.ANSI.reset()}"
  end

  def render_node(%{"type" => "Alert", "props" => p}) do
    tone = String.upcase(Map.get(p, "tone", "info"))
    msg = Map.get(p, "message", "")
    "[#{tone}] #{msg}"
  end

  def render_node(%{"type" => "Progress", "props" => p}) do
    label = Map.get(p, "label", "")
    pct = Map.get(p, "percent", 0)
    "▸ #{label}: #{pct}%"
  end

  def render_node(%{"type" => "Table", "props" => p}) do
    {headers, rows} = Renderers.extract_table(p)

    hdr_line = "  " <> Enum.join(headers, " | ")

    row_lines =
      Enum.map(rows, fn r ->
        "  " <> Enum.join(r, " | ")
      end)

    Enum.join([hdr_line | row_lines], "\n")
  end

  def render_node(%{"type" => "Panel", "props" => p}) do
    title = Map.get(p, "title", "Panel")

    items =
      (Map.get(p, "items") || Map.get(p, "children", []))
      |> Enum.map(fn
        i when is_binary(i) -> i
        i when is_map(i) -> render_node(i)
        i -> inspect(i)
      end)

    "▸ #{IO.ANSI.bright()}#{title}:#{IO.ANSI.reset()} " <> Enum.join(items, " ; ")
  end

  def render_node(other) do
    OpenUITUI.Renderers.PureANSI.render_node(other)
  end
end
