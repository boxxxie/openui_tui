defmodule OpenUITUI.Telemetry do
  @moduledoc """
  Telemetry collector, version correlation tagger, and JSONL persistence engine.

  Every LLM call, TypeSafe Jev judgment, cache hit/miss, OpenUI Lang parse/eval,
  TUI render, and budget alert is tagged with:
  - `run_id`: Unique session identifier
  - `program_version`: Version tag of the TUI maker program (e.g. `"0.2.0"`, `"v2-jev-router"`)
  - `prompt_version`: Version tag of the prompt template (e.g. `"v1-full-spec"`, `"v2-compact-tui"`)
  - `prompt_hash`: Short SHA-256 fingerprint of the prompt text
  - `experiment_tag`: Arbitrary experiment/branch label for A/B comparison

  All events are appended as structured JSON lines (`.jsonl`) to
  `OpenUITUI.Config.telemetry_jsonl_path/0` for historical review and version diffing.
  """

  use GenServer

  alias OpenUITUI.Config

  @handler_id "openui-tui-jsonl-telemetry-handler"

  @events [
    [:openui_tui, :llm, :call],
    [:openui_tui, :jev, :call],
    [:openui_tui, :cache, :lookup],
    [:openui_tui, :parser, :parse],
    [:openui_tui, :renderer, :render],
    [:openui_tui, :budget, :exceeded]
  ]

  # ── Client API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current active version/experiment context tags.
  """
  @spec current_tags() :: map()
  def current_tags do
    GenServer.call(__MODULE__, :current_tags)
  end

  @doc """
  Updates the active version/experiment correlation tags at runtime so you can
  benchmark multiple `program_version` or `prompt_version` configurations and
  compare their JSONL telemetry side-by-side.
  """
  @spec set_version_tags(keyword() | map()) :: :ok
  def set_version_tags(tags) do
    GenServer.call(__MODULE__, {:set_version_tags, Map.new(tags)})
  end

  @doc """
  Computes a short 12-char SHA-256 fingerprint for any prompt or schema string.
  """
  @spec fingerprint(String.t() | nil) :: String.t()
  def fingerprint(nil), do: "none"

  def fingerprint(text) when is_binary(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  Reads all historical telemetry records from the JSONL file (or a custom path).
  """
  @spec read_jsonl(String.t() | nil) :: [map()]
  def read_jsonl(path \\ nil) do
    target = path || Config.telemetry_jsonl_path()

    if File.exists?(target) do
      target
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> [map]
          _ -> []
        end
      end)
    else
      []
    end
  end

  @doc """
  Summarizes historical JSONL telemetry grouped by `program_version` and `prompt_version`,
  allowing side-by-side comparison of API calls, cache hit rates, token consumption,
  latency, and effective USD spend across versions.
  """
  @spec compare_versions(String.t() | nil) :: map()
  def compare_versions(jsonl_path \\ nil) do
    events = read_jsonl(jsonl_path)

    api_events =
      Enum.filter(events, fn e ->
        e["event"] in ["openui_tui.llm.call", "openui_tui.jev.call"]
      end)

    by_version =
      api_events
      |> Enum.group_by(fn e ->
        prog = e["program_version"] || "unknown"
        prompt = e["prompt_version"] || "unknown"
        exp = e["experiment_tag"] || "default"
        "#{prog} | #{prompt} | #{exp}"
      end)
      |> Map.new(fn {group_key, group_events} ->
        total_calls = length(group_events)

        cached_calls =
          Enum.count(group_events, fn e ->
            e["cache_status"] in ["hit_l1_cachex", "hit_l2_memcached"]
          end)

        live_calls = total_calls - cached_calls

        prompt_tokens =
          Enum.reduce(group_events, 0, fn e, acc -> acc + (e["prompt_tokens"] || 0) end)

        completion_tokens =
          Enum.reduce(group_events, 0, fn e, acc -> acc + (e["completion_tokens"] || 0) end)

        effective_spend =
          Enum.reduce(group_events, 0.0, fn e, acc -> acc + (e["effective_cost_usd"] || 0.0) end)

        raw_spend =
          Enum.reduce(group_events, 0.0, fn e, acc -> acc + (e["raw_cost_usd"] || 0.0) end)

        saved_spend =
          Enum.reduce(group_events, 0.0, fn e, acc -> acc + (e["saved_cost_usd"] || 0.0) end)

        avg_duration_ms =
          if total_calls > 0 do
            Float.round(
              Enum.reduce(group_events, 0.0, fn e, acc -> acc + (e["duration_ms"] || 0.0) end) /
                total_calls,
              2
            )
          else
            0.0
          end

        {group_key,
         %{
           total_calls: total_calls,
           live_network_calls: live_calls,
           cached_calls: cached_calls,
           cache_hit_rate_pct:
             if(total_calls > 0,
               do: Float.round(cached_calls / total_calls * 100.0, 1),
               else: 0.0
             ),
           prompt_tokens: prompt_tokens,
           completion_tokens: completion_tokens,
           total_tokens: prompt_tokens + completion_tokens,
           avg_tokens_per_call:
             if(total_calls > 0,
               do: Float.round((prompt_tokens + completion_tokens) / total_calls, 1),
               else: 0.0
             ),
           effective_spend_usd: Float.round(effective_spend, 6),
           raw_spend_usd: Float.round(raw_spend, 6),
           saved_by_cache_usd: Float.round(saved_spend, 6),
           avg_duration_ms: avg_duration_ms
         }}
      end)

    %{
      total_events_logged: length(events),
      total_api_events: length(api_events),
      versions: by_version
    }
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    run_id =
      "run_" <>
        Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S_") <>
        (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))

    state = %{
      run_id: run_id,
      program_version: Config.program_version(),
      prompt_version: Config.prompt_version(),
      experiment_tag: Config.experiment_tag()
    }

    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @events,
        &__MODULE__.handle_telemetry_event/4,
        nil
      )

    {:ok, state}
  end

  @impl true
  def handle_call(:current_tags, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_version_tags, new_tags}, _from, state) do
    updated =
      state
      |> Map.put(
        :program_version,
        Map.get(
          new_tags,
          :program_version,
          Map.get(new_tags, "program_version", state.program_version)
        )
      )
      |> Map.put(
        :prompt_version,
        Map.get(
          new_tags,
          :prompt_version,
          Map.get(new_tags, "prompt_version", state.prompt_version)
        )
      )
      |> Map.put(
        :experiment_tag,
        Map.get(
          new_tags,
          :experiment_tag,
          Map.get(new_tags, "experiment_tag", state.experiment_tag)
        )
      )
      |> Map.put(
        :run_id,
        Map.get(new_tags, :run_id, Map.get(new_tags, "run_id", state.run_id))
      )

    {:reply, :ok, updated}
  end

  @impl true
  def handle_cast({:record_event, event_name, measurements, metadata}, state) do
    write_jsonl_record(event_name, measurements, metadata, state)
    {:noreply, state}
  end

  @doc false
  def handle_telemetry_event(event_name, measurements, metadata, _config) do
    case Process.whereis(__MODULE__) do
      nil ->
        write_jsonl_record(event_name, measurements, metadata, %{
          run_id: "unsupervised",
          program_version: Config.program_version(),
          prompt_version: Config.prompt_version(),
          experiment_tag: Config.experiment_tag()
        })

      pid ->
        GenServer.cast(pid, {:record_event, event_name, measurements, metadata})
    end
  end

  defp write_jsonl_record(event_name, measurements, metadata, state) do
    jsonl_path = Config.telemetry_jsonl_path()
    :ok = File.mkdir_p(Path.dirname(jsonl_path))

    event_str = Enum.map_join(event_name, ".", &Atom.to_string/1)

    event_id =
      "evt_" <>
        Integer.to_string(System.system_time(:millisecond)) <>
        "_" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))

    record =
      %{
        event_id: event_id,
        event: event_str,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        run_id: Map.get(metadata, :run_id, state.run_id),
        program_version: Map.get(metadata, :program_version, state.program_version),
        prompt_version: Map.get(metadata, :prompt_version, state.prompt_version),
        experiment_tag: Map.get(metadata, :experiment_tag, state.experiment_tag)
      }
      |> Map.merge(sanitize_map(measurements))
      |> Map.merge(sanitize_map(metadata))

    case Jason.encode(record) do
      {:ok, json_line} ->
        File.write(jsonl_path, json_line <> "\n", [:append])

      _ ->
        :ok
    end
  end

  defp sanitize_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, sanitize_val(v)}
    end)
  end

  defp sanitize_val(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize_val(v) when is_atom(v), do: Atom.to_string(v)
  defp sanitize_val(v) when is_list(v), do: Enum.map(v, &sanitize_val/1)
  defp sanitize_val(v) when is_map(v), do: sanitize_map(v)
  defp sanitize_val(v), do: inspect(v)
end
