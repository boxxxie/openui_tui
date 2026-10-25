defmodule OpenUITUI do
  @moduledoc """
  OpenUI Lang Terminal User Interface (TUI) Maker for Elixir.

  Integrates:
  - `OpenUILang` 1.0 parser, streaming engine, and runtime evaluator
  - 5 Elixir TUI rendering engines (`:fixed_80`, `:pure_ansi`, `:owl`, `:table_rex`, `:compact_ops`)
  - Configurable LiteLLM Proxy (`OPENUI_LITELLM_URL` / `config/config.exs`) with `$1.00` spend cap (`OpenUITUI.SpendGuard`)
  - TypeSafe Jev (`typesafe/jev-latest`) SystemOne routing (treated as close-to-free)
  - Two-tier deduplication cache (`Cachex` L1 in-memory + `Memcached` L2 persistent daemon)
  - Version-tagged JSONL telemetry (`OpenUITUI.Telemetry`) and automated spend/learning reports (`OpenUITUI.SpendReport`)
  """

  alias OpenUITUI.{
    Cache,
    Catalog,
    Config,
    LayoutGuard,
    LiteLLMClient,
    Memcached,
    Renderers,
    Resolver,
    SourceNormalizer,
    SpendGuard,
    SpendReport,
    Telemetry,
    TUIRenderer
  }

  @doc """
  Parses and evaluates an OpenUI Lang program against the TUI component catalog
  and emits `[:openui_tui, :parser, :parse]` telemetry with compression ratio metrics.
  """
  @spec parse_and_evaluate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_and_evaluate(openui_code, _opts \\ []) when is_binary(openui_code) do
    t0 = System.monotonic_time(:microsecond)
    schema = Catalog.compiled_schema()
    parse_result = OpenUILang.parse(openui_code, schema)
    evaluated = OpenUILang.evaluate_result(parse_result, %{cat: schema})
    duration_us = System.monotonic_time(:microsecond) - t0

    openui_bytes = byte_size(String.trim(openui_code))

    json_bytes =
      case Jason.encode(evaluated["root"]) do
        {:ok, j} -> byte_size(j)
        _ -> 0
      end

    savings_pct =
      if json_bytes > 0 do
        Float.round((1.0 - openui_bytes / json_bytes) * 100.0, 1)
      else
        0.0
      end

    :telemetry.execute(
      [:openui_tui, :parser, :parse],
      %{
        duration_us: duration_us,
        openui_bytes: openui_bytes,
        equivalent_json_bytes: json_bytes,
        compression_savings_pct: savings_pct,
        statement_count: get_in(parse_result, [:meta, :statement_count]) || 0,
        error_count: length(evaluated["errors"] || [])
      },
      %{
        incomplete: evaluated["incomplete"] || false,
        schema_hash: Catalog.schema_hash()
      }
    )

    {:ok,
     %{
       parse_result: parse_result,
       evaluated: evaluated,
       root: evaluated["root"],
       errors: evaluated["errors"] || [],
       openui_bytes: openui_bytes,
       equivalent_json_bytes: json_bytes,
       compression_savings_pct: savings_pct,
       duration_us: duration_us
     }}
  end

  @doc """
  Renders an OpenUI Lang string or already-evaluated root map with the chosen TUI renderer
  (`:pure_ansi`, `:owl`, `:table_rex`, or `:compact_ops`).
  """
  @spec render(String.t() | map(), Renderers.renderer_id() | String.t()) :: String.t()
  def render(openui_code, renderer \\ :owl)

  def render(openui_code, renderer) when is_binary(openui_code) do
    {:ok, %{root: root}} = parse_and_evaluate(openui_code)
    Renderers.render(root, renderer)
  end

  def render(%{} = root, renderer) do
    Renderers.render(root, renderer)
  end

  @doc """
  Parses an OpenUI Lang program and renders it across all 4 Elixir TUI engines
  (`:pure_ansi`, `:owl`, `:table_rex`, `:compact_ops`) for comparison.
  """
  @spec compare_renderers(String.t() | map()) :: map()
  def compare_renderers(openui_code) when is_binary(openui_code) do
    {:ok, parsed} = parse_and_evaluate(openui_code)
    comparisons = Renderers.compare_all(parsed.root)

    Map.merge(parsed, %{
      renderers: comparisons
    })
  end

  def compare_renderers(%{} = root) do
    %{
      root: root,
      renderers: Renderers.compare_all(root)
    }
  end

  @doc """
  Simulates live LLM token streaming of `openui_code` in chunks of `chunk_size` bytes,
  using `OpenUILang.create_streaming_parser/1` and re-rendering on each progressive frame.
  """
  @spec simulate_streaming(String.t(), Renderers.renderer_id(), pos_integer()) :: [map()]
  def simulate_streaming(openui_code, renderer \\ :pure_ansi, chunk_size \\ 48) do
    schema = Catalog.compiled_schema()
    parser = OpenUILang.stream_parser(schema)
    chunks = chunk_binary(openui_code, chunk_size)
    total_chunks = length(chunks)

    {_, frames} =
      Enum.reduce(Enum.with_index(chunks, 1), {parser, []}, fn {chunk, idx}, {p, acc} ->
        t0 = System.monotonic_time(:microsecond)
        {parse_res, p_next} = OpenUILang.push_chunk(p, chunk, idx == total_chunks)
        evaluated = OpenUILang.evaluate_result(parse_res, %{cat: schema})

        rendered =
          if evaluated["root"], do: Renderers.render(evaluated["root"], renderer), else: ""

        elapsed_us = System.monotonic_time(:microsecond) - t0

        frame = %{
          frame_index: idx,
          chunk: chunk,
          statement_count: get_in(parse_res, [:meta, :statement_count]) || 0,
          incomplete: evaluated["incomplete"],
          has_root: evaluated["root"] != nil,
          elapsed_us: elapsed_us,
          rendered: rendered
        }

        {p_next, [frame | acc]}
      end)

    Enum.reverse(frames)
  end

  @doc """
  End-to-end LLM-powered TUI generation:
  1. Routes the request through TypeSafe Jev (`typesafe/jev-latest`, close-to-free) to pick
     archetype, density, and recommended renderer.
  2. Generates OpenUI Lang via LiteLLM (`gemini-2.5-flash-lite` or `gemini-3.5-flash-lite`),
     served from `Cachex` (L1) or `Memcached` (L2) on duplicate requests, and gated by
     the `$1.00` `SpendGuard` budget.
  3. Parses, validates, and evaluates the generated OpenUI Lang code.
  4. Renders the result across all 4 Elixir TUI engines.
  """
  @spec generate_tui(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_tui(user_prompt, opts \\ []) when is_binary(user_prompt) do
    with {:ok, llm_res} <- LiteLLMClient.generate_openui(user_prompt, opts),
         {:ok, parsed} <- parse_and_evaluate(llm_res.content) do
      recommended =
        get_in(llm_res, [:jev_routing, :recommended_renderer]) || "owl"

      all_renders =
        if parsed.root do
          Renderers.compare_all(parsed.root)
        else
          %{}
        end

      {:ok,
       %{
         prompt: user_prompt,
         model: llm_res.model,
         cache_status: llm_res.cache_status,
         jev_routing: llm_res.jev_routing,
         recommended_renderer: recommended,
         openui_code: llm_res.content,
         root: parsed.root,
         errors: parsed.errors,
         openui_bytes: parsed.openui_bytes,
         equivalent_json_bytes: parsed.equivalent_json_bytes,
         compression_savings_pct: parsed.compression_savings_pct,
         prompt_tokens: llm_res.prompt_tokens,
         completion_tokens: llm_res.completion_tokens,
         raw_cost_usd: llm_res.raw_cost_usd,
         effective_cost_usd: llm_res.effective_cost_usd,
         renderers: all_renders,
         primary_output: if(parsed.root, do: Renderers.render(parsed.root, recommended), else: "")
       }}
    end
  end

  @doc """
  Updates the active telemetry version/experiment correlation tags (`program_version`,
  `prompt_version`, `experiment_tag`, `run_id`).
  """
  @spec set_version_tags(keyword() | map()) :: :ok
  defdelegate set_version_tags(tags), to: Telemetry

  @doc """
  Compares API metrics, token consumption, cache hit rates, and spend across all recorded
  `program_version | prompt_version | experiment_tag` cohorts in the JSONL telemetry file.
  """
  @spec compare_versions(String.t() | nil) :: map()
  defdelegate compare_versions(jsonl_path \\ nil), to: Telemetry

  @doc """
  Generates and saves a full Markdown + OpenUI Lang spend review report.
  """
  @spec generate_spend_report!(map()) :: map()
  defdelegate generate_spend_report!(opts \\ %{}), to: SpendReport, as: :generate_and_save!

  @doc """
  Returns the current `SpendGuard` ledger status and health of `Memcached` + `LiteLLM`.
  """
  @spec system_status() :: map()
  def system_status do
    %{
      spend_ledger: SpendGuard.status(),
      memcached: Memcached.ping(),
      version_tags: Telemetry.current_tags(),
      telemetry_jsonl_path: Config.telemetry_jsonl_path(),
      cache_l1: :openui_tui_cache
    }
  end

  @doc """
  Directly checks `Cache.fetch/2` for testing or inspection.
  """
  defdelegate fetch_cache(key), to: Cache, as: :fetch

  @doc """
  Resolves an OpenUI Lang program or symbol map via `OpenUITUI.Resolver.resolve_root/2`,
  clamps it to the 80-column terminal budget via `OpenUITUI.LayoutGuard.clamp/2`, and
  renders fixed-width 80-column lines via `OpenUITUI.TUIRenderer.render/2`.
  """
  @spec resolve_and_render_80col(String.t() | map(), keyword()) :: [String.t()]
  def resolve_and_render_80col(code_or_symbols, opts \\ []) do
    ui_state = Keyword.get(opts, :ui_state, %{})

    code_or_symbols
    |> Resolver.resolve_root(ui_state)
    |> LayoutGuard.clamp()
    |> TUIRenderer.render(opts)
  end

  @doc """
  Pre-flight tool for LLM agents: introspects an allowlisted `"exec"`, `"tcp"`, or `"beam"`
  metric source once and returns `%{row_count, available_keys, sample_row}`.
  """
  defdelegate inspect_metric_source(transport, target, format), to: SourceNormalizer

  @doc """
  Demultiplexes mixed conversational Markdown prose and OpenUI Lang code blocks.
  """
  defdelegate demux(input), to: OpenUILang

  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<part::binary-size(size), rest::binary>> = bin
    [part | chunk_binary(rest, size)]
  end
end
