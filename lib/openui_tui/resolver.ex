defmodule OpenUITUI.Resolver do
  @moduledoc """
  Resolves a flat map of parsed OpenUI statements (`%{"root" => ast_node, ...}`)
  into a nested tuple AST, replacing missing forward references with
  `{:unresolved, identifier}` skeleton nodes and clamping the tree to 80 columns
  via `OpenUITUI.LayoutGuard`.

  Tracks visited identifiers in a `MapSet` so cyclic LLM hallucinations never
  cause an infinite loop.
  """

  alias OpenUITUI.LayoutGuard

  @type symbol_table :: %{optional(String.t()) => term()}

  @doc """
  Resolves `"root"` from a symbol table map (or parses an OpenUI Lang source string
  into a symbol table first), substitutes `$var` bindings from `symbols` / `ui_state`,
  and clamps the tree via `LayoutGuard.clamp/2`.
  """
  @spec resolve_root(symbol_table() | String.t(), map()) :: term()
  def resolve_root(symbols_or_code, ui_state \\ %{})

  def resolve_root(code, ui_state) when is_binary(code) do
    code
    |> OpenUILang.parse_symbols()
    |> resolve_root(ui_state)
  end

  def resolve_root(symbols, ui_state) when is_map(symbols) do
    merged_symbols = Map.merge(symbols, ui_state)

    case Map.fetch(merged_symbols, "root") do
      {:ok, root_ast} ->
        root_ast
        |> resolve_node(merged_symbols, MapSet.new(["root"]))
        |> LayoutGuard.clamp()

      :error ->
        {:unresolved, "root"}
    end
  end

  @doc """
  Interpolates an action or expression node against the current `symbols` and `ui_state`.
  """
  @spec evaluate_expr(term(), map()) :: term()
  def evaluate_expr(node, symbols) when is_map(symbols) do
    resolve_node(node, symbols, MapSet.new())
  end

  # Reference tuple emitted by OpenUI parser: {:ref, "cpu_stat"}
  defp resolve_node({:ref, var_name}, symbols, visited) when is_binary(var_name) do
    if MapSet.member?(visited, var_name) do
      {:unresolved, var_name}
    else
      case Map.fetch(symbols, var_name) do
        {:ok, target} -> resolve_node(target, symbols, MapSet.put(visited, var_name))
        :error -> {:unresolved, var_name}
      end
    end
  end

  # Reactive state binding: {:var, "$target_env"} -> look up current value or default
  defp resolve_node({:var, var_name}, symbols, _visited) when is_binary(var_name) do
    Map.get(symbols, var_name, "")
  end

  # Binary string concatenation / arithmetic / comparison in expressions
  defp resolve_node({:bin_op, "+", left, right}, symbols, visited) do
    l = resolve_node(left, symbols, visited)
    r = resolve_node(right, symbols, visited)

    if is_number(l) and is_number(r) do
      l + r
    else
      safe_str(l) <> safe_str(r)
    end
  end

  defp resolve_node({:bin_op, op, left, right}, symbols, visited) do
    l = resolve_node(left, symbols, visited)
    r = resolve_node(right, symbols, visited)

    case op do
      "==" -> l == r
      "!=" -> l != r
      ">" when is_number(l) and is_number(r) -> l > r
      "<" when is_number(l) and is_number(r) -> l < r
      ">=" when is_number(l) and is_number(r) -> l >= r
      "<=" when is_number(l) and is_number(r) -> l <= r
      "-" when is_number(l) and is_number(r) -> l - r
      "*" when is_number(l) and is_number(r) -> l * r
      "/" when is_number(l) and is_number(r) and r != 0 -> l / r
      _ -> safe_str(l)
    end
  end

  defp resolve_node({:ternary, cond_ast, then_ast, else_ast}, symbols, visited) do
    c = resolve_node(cond_ast, symbols, visited)

    if c not in [false, nil, "", 0, "false"] do
      resolve_node(then_ast, symbols, visited)
    else
      resolve_node(else_ast, symbols, visited)
    end
  end

  # Preserve reactive variable binding inside interactive form controls (Field, Select, Toggle)
  # while also attaching the current resolved value
  defp resolve_node({"Field", [label, {:var, var_name} | rest]}, symbols, visited) do
    val = Map.get(symbols, var_name, "")
    resolved_rest = Enum.map(rest, &resolve_node(&1, symbols, visited))
    {"Field", [resolve_node(label, symbols, visited), val | resolved_rest]}
  end

  defp resolve_node({"Select", [label, {:var, var_name} | rest]}, symbols, visited) do
    val = Map.get(symbols, var_name, "")
    resolved_rest = Enum.map(rest, &resolve_node(&1, symbols, visited))
    {"Select", [resolve_node(label, symbols, visited), val | resolved_rest]}
  end

  defp resolve_node({"Toggle", [label, {:var, var_name} | rest]}, symbols, visited) do
    val = Map.get(symbols, var_name, false)
    resolved_rest = Enum.map(rest, &resolve_node(&1, symbols, visited))
    {"Toggle", [resolve_node(label, symbols, visited), val | resolved_rest]}
  end

  # Component call: {"Panel", [title, children, tone]}
  defp resolve_node({component, args}, symbols, visited)
       when is_binary(component) and is_list(args) do
    {component, Enum.map(args, &resolve_node(&1, symbols, visited))}
  end

  defp resolve_node(list, symbols, visited) when is_list(list) do
    Enum.map(list, &resolve_node(&1, symbols, visited))
  end

  defp resolve_node(literal, _symbols, _visited), do: literal

  defp safe_str(nil), do: ""
  defp safe_str(v) when is_binary(v), do: v
  defp safe_str(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp safe_str({:unresolved, ref}), do: "{#{ref}}"
  defp safe_str({"Badge", [lbl | _]}), do: "[#{safe_str(lbl)}]"
  defp safe_str({comp, [first | _]}) when is_binary(comp), do: safe_str(first)
  defp safe_str(list) when is_list(list), do: Enum.map_join(list, ", ", &safe_str/1)
  defp safe_str(other), do: inspect(other)
end
