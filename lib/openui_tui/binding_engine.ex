defmodule OpenUITUI.BindingEngine do
  @moduledoc """
  Evaluates declarative `Bind(var, source_id, path, transform, template?)` statements
  against normalized source snapshots (`OpenUITUI.SourceNormalizer`), maintaining:
  - Previous scalar samples & timestamps to calculate per-second rates (`"rate"` and `"spark_rate"`)
  - 18-point ring buffers keyed by target variable name (`"$cpu_spark"`) for `"spark_value"` and `"spark_rate"`
  - 2D row & `BarItem` projections for `"rows"` and `"bars"`
  """

  alias OpenUITUI.SourceNormalizer

  @spark_window 18

  defstruct prev_scalars: %{},
            prev_ts: %{},
            spark_buffers: %{}

  @type t :: %__MODULE__{}

  @doc """
  Applies all `Bind` definitions in `symbols` for `source_id` using the latest `rows` snapshot.
  Returns `{updated_engine_state, new_symbol_bindings_map}`.
  """
  @spec evaluate_source(t(), map(), String.t(), [map()]) :: {t(), map()}
  def evaluate_source(%__MODULE__{} = state, symbols, source_id, rows) when is_list(rows) do
    now_ms = System.monotonic_time(:millisecond)
    bind_nodes = OpenUITUI.LiveSession.collect_tag_nodes(symbols, "Bind")

    binds =
      Enum.flat_map(bind_nodes, fn
        {"Bind", [{:var, var_name}, ^source_id, path, transform | rest]} ->
          [{var_name, path, transform, List.first(rest)}]

        {"Bind", [{:var, var_name}, ^source_id, path]} ->
          [{var_name, path, "value", nil}]

        {"Bind", [var_str, ^source_id, path, transform | rest]} when is_binary(var_str) ->
          norm_var = if String.starts_with?(var_str, "$"), do: var_str, else: "$" <> var_str
          [{norm_var, path, transform, List.first(rest)}]

        _ ->
          []
      end)

    Enum.reduce(binds, {state, %{}}, fn {var_name, path, transform, template}, {st, acc} ->
      {next_st, computed_val} =
        apply_transform(st, var_name, rows, path, transform, template, now_ms)

      {next_st, Map.put(acc, var_name, computed_val)}
    end)
  end

  # 1. Scalar Value ("value")
  defp apply_transform(state, _var, rows, key, "value", template, _now_ms) when is_binary(key) do
    raw_val = extract_latest_scalar(rows, key, 0)
    {state, format_template(raw_val, template)}
  end

  # 2. Per-Second Rate ("rate") for cumulative counters
  defp apply_transform(state, var, rows, key, "rate", template, now_ms) when is_binary(key) do
    curr = extract_latest_number(rows, key)
    {next_state, rate} = compute_rate(state, var, curr, now_ms)
    {next_state, format_template(rate, template)}
  end

  # 3. Rolling Sparkline of Raw Values ("spark_value")
  defp apply_transform(state, var, rows, key, "spark_value", _template, _now_ms)
       when is_binary(key) do
    curr = extract_latest_number(rows, key)
    next_state = push_spark(state, var, curr)
    {next_state, Map.get(next_state.spark_buffers, var, [])}
  end

  # 4. Rolling Sparkline of Per-Second Rates ("spark_rate")
  defp apply_transform(state, var, rows, key, "spark_rate", _template, now_ms)
       when is_binary(key) do
    curr = extract_latest_number(rows, key)
    {state_with_rate, rate} = compute_rate(state, var, curr, now_ms)
    next_state = push_spark(state_with_rate, var, rate)
    {next_state, Map.get(next_state.spark_buffers, var, [])}
  end

  # 5. Table Row Projection ("rows"): path is ["col1", "col2", ...]
  defp apply_transform(state, _var, rows, keys, "rows", _template, _now_ms) when is_list(keys) do
    projected =
      rows
      |> Enum.take(8)
      |> Enum.map(fn row_map ->
        Enum.map(keys, fn k -> to_string(Map.get(row_map, k, "")) end)
      end)

    {state, projected}
  end

  # 6. BarList Projection ("bars"): path is [label_key, numeric_pct_key, right_text_key]
  defp apply_transform(state, _var, rows, [l_key, val_key | rest], "bars", _template, _now_ms) do
    text_key = List.first(rest) || val_key

    bar_items =
      rows
      |> Enum.take(6)
      |> Enum.map(fn row_map ->
        label = to_string(Map.get(row_map, l_key, "item"))
        num_val = to_number(Map.get(row_map, val_key, 0))
        right_text = to_string(Map.get(row_map, text_key, "#{num_val}%"))
        {"BarItem", [label, num_val, right_text]}
      end)

    {state, bar_items}
  end

  defp apply_transform(state, _var, _rows, _path, _unknown, _template, _now_ms) do
    {state, ""}
  end

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS: Rate Diffs & Bounded Ring Buffers
  # ---------------------------------------------------------------------------

  defp compute_rate(state, var, curr_val, now_ms) do
    prev_val = Map.get(state.prev_scalars, var, curr_val)
    prev_ts = Map.get(state.prev_ts, var, now_ms - 1000)
    dt_sec = max((now_ms - prev_ts) / 1000.0, 0.1)

    rate = round(max(curr_val - prev_val, 0) / dt_sec)

    next_state = %{
      state
      | prev_scalars: Map.put(state.prev_scalars, var, curr_val),
        prev_ts: Map.put(state.prev_ts, var, now_ms)
    }

    {next_state, rate}
  end

  defp push_spark(state, var, number_val) do
    current_buf = Map.get(state.spark_buffers, var, List.duplicate(number_val, @spark_window))
    updated_buf = Enum.take(current_buf ++ [number_val], -@spark_window)
    %{state | spark_buffers: Map.put(state.spark_buffers, var, updated_buf)}
  end

  defp extract_latest_scalar([], _key, default), do: default
  defp extract_latest_scalar(rows, key, default), do: rows |> List.last() |> Map.get(key, default)

  defp extract_latest_number(rows, key) do
    rows |> extract_latest_scalar(key, 0) |> to_number()
  end

  defp to_number(v) when is_number(v), do: v
  defp to_number(v) when is_binary(v), do: SourceNormalizer.coerce_scalar(v) |> ensure_num()
  defp to_number(_), do: 0

  defp ensure_num(v) when is_number(v), do: v
  defp ensure_num(_), do: 0

  defp format_template(val, nil), do: to_string(val)

  defp format_template(val, template) when is_binary(template) do
    String.replace(template, "{val}", to_string(val))
  end
end
