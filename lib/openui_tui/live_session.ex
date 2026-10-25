defmodule OpenUITUI.LiveSession do
  @moduledoc """
  Two-loop stateful TUI session GenServer bridging:
  1. **The LLM Control Plane (Runs Once per Prompt)**: Streams or merges OpenUI Lang
     statements into `symbols`, seeding default `$var` values into `ui_state` only once
     so streaming tokens never clobber user input or focus.
  2. **The BEAM Data Plane (Runs at 1–10 Hz)**: Detects `StreamSource(...)` and `Bind(...)`
     nodes in `symbols`, polls local services (`memcached`, `vmstat`, `beam`, etc.) without
     consuming LLM tokens, updates `$live_*` bindings, and re-renders the 80-column frame.
  """

  use GenServer

  alias OpenUITUI.{BindingEngine, Resolver, SourceNormalizer, TUIRenderer}
  alias OpenUITUI.LLMTelemetry.Parser, as: LLMTelemetryParser
  alias OpenUITUI.Memcached.Probe

  defstruct symbols: %{},
            ui_state: %{},
            probe: %Probe{},
            binding_engine: %BindingEngine{},
            polling_target: nil,
            llm_telemetry?: false,
            generic_sources: %{},
            interval_ms: 1_000,
            tick: 0,
            auto_poll?: false,
            write_tty?: false

  @type t :: %__MODULE__{}

  # ── Client API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Parses an OpenUI Lang string (complete or partial chunk) and merges its symbols
  into the live session without clobbering existing `ui_state` user edits.
  """
  @spec load_openui(GenServer.server(), String.t()) :: :ok
  def load_openui(server, openui_code) when is_binary(openui_code) do
    symbols = OpenUILang.parse_symbols(openui_code)
    merge_parsed_symbols(server, symbols)
  end

  @doc """
  Merges a map of parsed OpenUI symbols into the session and activates any declared
  `StreamSource` pollers.
  """
  @spec merge_parsed_symbols(GenServer.server(), map()) :: :ok
  def merge_parsed_symbols(server, new_symbols) when is_map(new_symbols) do
    GenServer.call(server, {:merge_parsed_symbols, new_symbols})
  end

  @doc """
  Updates a user-editable `$var` in `ui_state` (e.g. from keyboard input in a `Field`,
  `Select`, or `Toggle`). Protected against overwrites when new LLM tokens arrive.
  """
  @spec put_ui_state(GenServer.server(), String.t(), term()) :: :ok
  def put_ui_state(server, var_name, value) when is_binary(var_name) do
    GenServer.call(server, {:put_ui_state, var_name, value})
  end

  @doc """
  Executes one immediate poll cycle across all active `StreamSource`s (`memcached` and
  generic `exec`/`tcp`/`beam` sources) and increments `tick`.
  """
  @spec poll_now(GenServer.server()) :: {:ok, [String.t()]}
  def poll_now(server) do
    GenServer.call(server, :poll_now)
  end

  @doc """
  Renders the current 80-column TUI frame as a list of lines (`[String.t()]`).
  """
  @spec render_lines(GenServer.server(), keyword()) :: [String.t()]
  def render_lines(server, opts \\ []) do
    GenServer.call(server, {:render_lines, opts})
  end

  @doc """
  Interpolates a button's `Action` by variable identifier (e.g. `"btn_apply"` or `"btn_analyze"`)
  against the current `symbols` and `ui_state`.
  """
  @spec dispatch_action(GenServer.server(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def dispatch_action(server, button_id) when is_binary(button_id) do
    GenServer.call(server, {:dispatch_action, button_id})
  end

  @doc """
  Returns the internal session state for inspection.
  """
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %__MODULE__{
      auto_poll?: Keyword.get(opts, :auto_poll, false),
      write_tty?: Keyword.get(opts, :write_tty, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:merge_parsed_symbols, new_symbols}, _from, state) do
    # Seed initial default values for $vars into ui_state ONLY if not already present
    seeded_ui_state =
      Enum.reduce(new_symbols, state.ui_state, fn
        {"$" <> _ = var_key, default_val}, acc ->
          Map.put_new(acc, var_key, default_val)

        _, acc ->
          acc
      end)

    merged_symbols = Map.merge(state.symbols, new_symbols)

    state =
      %{state | symbols: merged_symbols, ui_state: seeded_ui_state}
      |> maybe_activate_stream_sources()

    maybe_write_tty(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put_ui_state, var_name, value}, _from, state) do
    key = if String.starts_with?(var_name, "$"), do: var_name, else: "$" <> var_name
    updated = %{state | ui_state: Map.put(state.ui_state, key, value)}
    maybe_write_tty(updated)
    {:reply, :ok, updated}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    updated = execute_poll_cycle(state)
    lines = render_state_lines(updated, [])
    {:reply, {:ok, lines}, updated}
  end

  @impl true
  def handle_call({:render_lines, opts}, _from, state) do
    {:reply, render_state_lines(state, opts), state}
  end

  @impl true
  def handle_call({:dispatch_action, button_id}, _from, state) do
    merged = Map.merge(state.symbols, state.ui_state)

    case Map.get(merged, button_id) do
      {"Button", [_label, action_ast | _]} ->
        resolved = Resolver.evaluate_expr(action_ast, merged)
        {:reply, {:ok, resolved}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:poll_tick, state) do
    updated = execute_poll_cycle(state)
    maybe_write_tty(updated)

    if updated.auto_poll? do
      Process.send_after(self(), :poll_tick, updated.interval_ms)
    end

    {:noreply, updated}
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────

  defp maybe_activate_stream_sources(state) do
    stream_nodes = collect_tag_nodes(state.symbols, "StreamSource")

    # 1. Check Memcached StreamSource("memcached", target?, interval_ms?)
    state =
      case Enum.find_value(stream_nodes, fn
             {"StreamSource", ["memcached", target, interval_ms | _]}
             when is_binary(target) and is_integer(interval_ms) ->
               {target, interval_ms}

             {"StreamSource", ["memcached", target]} when is_binary(target) ->
               {target, 1_000}

             {"StreamSource", ["memcached"]} ->
               {"127.0.0.1:11211", 1_000}

             _ ->
               nil
           end) do
        {target, interval_ms} ->
          [host, port_str] =
            case String.split(target, ":", parts: 2) do
              [h, p] -> [h, p]
              [h] -> [h, "11211"]
            end

          port =
            case Integer.parse(port_str) do
              {p_int, _} -> p_int
              :error -> 11_211
            end

          next = %{state | polling_target: {host, port}, interval_ms: max(interval_ms, 250)}
          if next.auto_poll?, do: send(self(), :poll_tick)
          next

        nil ->
          state
      end

    # 1b. Check OpenUI TUI LLM & Jev Telemetry StreamSource("openui_telemetry", ...)
    has_llm_telemetry? =
      Enum.any?(stream_nodes, fn
        {"StreamSource", [kind | _]}
        when kind in ["openui_telemetry", "litellm", "llm_telemetry"] ->
          true

        {"StreamSource", [_id, "beam", "openui_tui:llm_telemetry" | _]} ->
          true

        _ ->
          false
      end)

    state = %{state | llm_telemetry?: has_llm_telemetry?}

    # 2. Check Generic StreamSource(id, transport, target, format?, interval_ms?)
    generic =
      Enum.reduce(stream_nodes, %{}, fn
        {"StreamSource", [id, transport, target, format, interval_ms | _]}, acc
        when is_binary(id) and is_binary(transport) and is_binary(target) and is_binary(format) ->
          Map.put(acc, id, %{
            id: id,
            transport: transport,
            target: target,
            format: format,
            interval_ms: if(is_integer(interval_ms), do: max(interval_ms, 250), else: 1_000)
          })

        {"StreamSource", [id, "beam", target | rest]}, acc
        when is_binary(id) and is_binary(target) ->
          interval = Enum.find(rest, 1_000, &is_integer/1)

          Map.put(acc, id, %{
            id: id,
            transport: "beam",
            target: target,
            format: "term",
            interval_ms: max(interval, 250)
          })

        {"StreamSource", [id, "exec", target | rest]}, acc
        when is_binary(id) and is_binary(target) ->
          interval = Enum.find(rest, 2_000, &is_integer/1)

          Map.put(acc, id, %{
            id: id,
            transport: "exec",
            target: target,
            format: "columns",
            interval_ms: max(interval, 500)
          })

        _, acc ->
          acc
      end)

    %{state | generic_sources: Map.merge(state.generic_sources, generic)}
  end

  @doc false
  def collect_tag_nodes(term, tag) when is_map(term) do
    term
    |> Map.values()
    |> Enum.flat_map(&collect_tag_nodes(&1, tag))
  end

  def collect_tag_nodes({tag, args} = node, tag) when is_list(args) do
    [node | Enum.flat_map(args, &collect_tag_nodes(&1, tag))]
  end

  def collect_tag_nodes({_other_tag, args}, tag) when is_list(args) do
    Enum.flat_map(args, &collect_tag_nodes(&1, tag))
  end

  def collect_tag_nodes(list, tag) when is_list(list) do
    Enum.flat_map(list, &collect_tag_nodes(&1, tag))
  end

  def collect_tag_nodes(_, _tag), do: []

  defp execute_poll_cycle(state) do
    # Poll dedicated Memcached probe if configured
    state =
      case state.polling_target do
        {host, port} ->
          case Probe.fetch_raw(host, port) do
            {:ok, raw_stats} ->
              {next_probe, live_bindings} = Probe.compute_live_bindings(state.probe, raw_stats)
              %{state | probe: next_probe, symbols: Map.merge(state.symbols, live_bindings)}

            {:error, reason} ->
              err_banner = %{"$live_uptime_footer" => "TCP DISCONNECTED (#{inspect(reason)})"}
              %{state | symbols: Map.merge(state.symbols, err_banner)}
          end

        nil ->
          state
      end

    # Poll OpenUI TUI LLM & Jev Telemetry (events.jsonl + SpendGuard) if configured
    state =
      if state.llm_telemetry? do
        llm_bindings = LLMTelemetryParser.collect_live_bindings()
        %{state | symbols: Map.merge(state.symbols, llm_bindings)}
      else
        state
      end

    # Poll generic StreamSources + evaluate Bind statements
    state =
      Enum.reduce(state.generic_sources, state, fn {source_id, spec}, acc_state ->
        case SourceNormalizer.fetch_and_normalize(spec.transport, spec.target, spec.format) do
          {:ok, rows} ->
            {next_engine, new_bindings} =
              BindingEngine.evaluate_source(
                acc_state.binding_engine,
                acc_state.symbols,
                source_id,
                rows
              )

            %{
              acc_state
              | binding_engine: next_engine,
                symbols: Map.merge(acc_state.symbols, new_bindings)
            }

          {:error, _reason} ->
            acc_state
        end
      end)

    %{state | tick: state.tick + 1}
  end

  defp render_state_lines(state, opts) do
    render_opts =
      opts
      |> Keyword.put_new(:ansi?, true)
      |> Keyword.put_new(:tick, state.tick)

    state.symbols
    |> Resolver.resolve_root(state.ui_state)
    |> TUIRenderer.render(render_opts)
  end

  defp maybe_write_tty(%{write_tty?: true} = state) do
    lines = render_state_lines(state, ansi?: true)
    IO.write([IO.ANSI.home(), Enum.join(lines, "\r\n")])
  end

  defp maybe_write_tty(_state), do: :ok
end
