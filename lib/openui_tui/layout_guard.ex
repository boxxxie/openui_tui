defmodule OpenUITUI.LayoutGuard do
  @moduledoc """
  Defensive AST clamping pass between the OpenUI resolver/evaluator and TUI renderers.

  Enforces 80-column terminal geometry invariants (76 inner columns):
  1. Demotes nested `Panel`s (`depth > 0`) inside another `Panel` into a `Divider` + `Stack`,
     while allowing section `Panel` cards inside `Dashboard` or `Row`.
  2. Unwraps `Row` into a vertical `Stack` if the LLM placed a `Table`, `Form`, or `> 3` items inside it.
  3. Caps `Table` columns at 4 and proportionally rescales column widths (`sum <= 64`) to fit inside 76 inner columns.
  """

  @max_inner_cols 76
  @max_table_cols 4

  @doc """
  Clamps a resolved OpenUI tuple AST (or evaluated element map) to fit an 80-column terminal budget.
  """
  @spec clamp(term(), non_neg_integer()) :: term()
  def clamp(ast, depth \\ 0)

  # 1. Demote nested Panels (depth > 0) into a Divider + Stack so borders never stack
  def clamp({"Panel", [title, children | _rest]}, depth) when depth > 0 and is_list(children) do
    clamped_children = Enum.map(children, &clamp(&1, depth + 1))
    {"Stack", [[{"Divider", [title]} | clamped_children], 0]}
  end

  def clamp({"Panel", [title, children | rest]}, 0) when is_list(children) do
    clamped_children = Enum.map(children, &clamp(&1, 1))
    {"Panel", [title, clamped_children | rest]}
  end

  # Inside Dashboard, allow direct child Panels (depth 0) so section cards render with borders
  def clamp({"Dashboard", [title, subtitle, children | rest]}, 0) when is_list(children) do
    clamped_children = Enum.map(children, &clamp(&1, 0))
    {"Dashboard", [title, subtitle, clamped_children | rest]}
  end

  # 2. Unwrap Row into a vertical Stack if the LLM put a Table, Form, or >3 items inside it
  def clamp({"Row", [children]}, _depth) when is_list(children) do
    clamped = Enum.map(children, &clamp(&1, 0))

    if length(clamped) > 3 or Enum.any?(clamped, &wide_block?/1) do
      {"Stack", [clamped, 1]}
    else
      {"Row", [clamped]}
    end
  end

  # 3. Cap Table columns at 4 and proportionally scale widths to fit 76 inner columns
  def clamp({"Table", [cols, rows | rest]}, _depth) when is_list(cols) and is_list(rows) do
    if Enum.any?(cols, &match?({:unresolved, _}, &1)) do
      {"Table", [cols, rows | rest]}
    else
      kept_cols = cols |> Enum.take(@max_table_cols) |> rescale_columns(@max_inner_cols)
      col_count = length(kept_cols)

      trimmed_rows =
        Enum.map(rows, fn
          row when is_list(row) -> Enum.take(row, col_count)
          {:unresolved, _} = skel -> skel
          _other -> []
        end)

      {"Table", [kept_cols, trimmed_rows | rest]}
    end
  end

  def clamp({"Table", [cols]}, _depth) when is_list(cols) do
    if Enum.any?(cols, &match?({:unresolved, _}, &1)) do
      {"Table", [cols]}
    else
      {"Table", [Enum.take(cols, @max_table_cols)]}
    end
  end

  def clamp({component, [children | rest]}, depth)
      when component in ["Stack", "BarList"] and is_list(children) do
    {component, [Enum.map(children, &clamp(&1, depth + 1)) | rest]}
  end

  def clamp(other, _depth), do: other

  defp wide_block?({name, _}) when name in ["Table", "Form", "BarList"], do: true
  defp wide_block?(_), do: false

  defp rescale_columns([], _budget), do: []

  defp rescale_columns(cols, budget) do
    separator_cost = max(length(cols) - 1, 0) * 3
    available = budget - separator_cost - 2

    raw_widths =
      Enum.map(cols, fn
        {"Col", [_hdr, w | _]} when is_integer(w) and w > 0 -> w
        _ -> 14
      end)

    total_raw = Enum.sum(raw_widths)

    if total_raw <= available do
      cols
    else
      scale = available / max(total_raw, 1)

      Enum.map(cols, fn
        {"Col", [hdr, w | rest]} when is_integer(w) ->
          {"Col", [hdr, max(trunc(w * scale), 6) | rest]}

        other ->
          other
      end)
    end
  end
end
