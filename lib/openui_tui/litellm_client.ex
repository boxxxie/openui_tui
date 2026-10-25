defmodule OpenUITUI.LiteLLMClient do
  @moduledoc """
  LiteLLM Proxy client (`OpenUITUI.Config.litellm_url/0`) with:
  - Two-tier caching (`Cachex` L1 + `Memcached` L2) to avoid spending money on duplicate calls
  - Real-time `$1.00` spend enforcement (`OpenUITUI.SpendGuard`)
  - Default cheap Gemini models (`gemini-2.5-flash-lite`, `gemini-3.5-flash-lite`)
  - Close-to-free TypeSafe Jev SystemOne judgments (`typesafe/jev-latest`)
  - Automatic version-tagged JSONL telemetry (`OpenUITUI.Telemetry`)
  """

  alias OpenUITUI.{Cache, Catalog, Config, SpendGuard, Telemetry}

  @doc """
  Uses TypeSafe Jev (`typesafe/jev-latest`) on `/v1/systemone` to classify a TUI request
  into an archetype, recommended Elixir renderer, and display density in ~190ms.

  Per project guidelines, Jev calls are treated as close-to-free (`effective_cost_usd = 0.0`)
  and are cached in `Cachex` + `Memcached`.
  """
  @spec route_tui_request(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def route_tui_request(user_prompt, opts \\ []) when is_binary(user_prompt) do
    questions = %{
      "archetype" => %{
        "type" => "choice",
        "instructions" => "Select the best TUI dashboard archetype for the user's request.",
        "criteria" => %{
          "metrics_dashboard" =>
            "Server health, KPIs, resource utilization bars, and status tables",
          "incident_triage" =>
            "Active alerts, error logs, failing services, and remediation steps",
          "table_explorer" => "Data-heavy tabular comparison, records, or inventory listing",
          "cost_audit" => "LLM spend, token budgets, cache hit rates, and telemetry analysis"
        }
      },
      "recommended_renderer" => %{
        "type" => "choice",
        "instructions" => "Select the most suitable Elixir TUI rendering engine for this view.",
        "criteria" => %{
          "owl" =>
            "Rich bordered boxes, tagged status colors, progress bars, and structured panels",
          "table_rex" => "Data-dense ASCII/Unicode tables with multi-column alignment",
          "pure_ansi" => "Zero-dependency fast ANSI streamable layout with Unicode box-drawing",
          "compact_ops" => "Ultra-dense single-screen DevOps/SRE summary"
        }
      },
      "density" => %{
        "type" => "choice",
        "instructions" => "Choose the appropriate information density.",
        "criteria" => %{
          "compact" => "Brief, high-signal summary for quick terminal scanning",
          "standard" => "Balanced KPIs, table, and summary panel",
          "detailed" => "Comprehensive breakdown with full metrics and diagnostics"
        }
      }
    }

    with {:ok, res} <- jev_decision(%{"request" => user_prompt}, questions, opts) do
      answers = Map.get(res.body, "answers", %{})

      routing = %{
        archetype: get_in(answers, ["archetype", "choice"]) || "metrics_dashboard",
        archetype_confidence: get_in(answers, ["archetype", "confidence"]) || 1.0,
        recommended_renderer: get_in(answers, ["recommended_renderer", "choice"]) || "owl",
        density: get_in(answers, ["density", "choice"]) || "standard",
        cache_status: res.cache_status,
        raw_cost_usd: res.raw_cost_usd,
        effective_cost_usd: 0.0,
        duration_ms: res.duration_ms
      }

      {:ok, routing}
    end
  end

  @doc """
  Uses TypeSafe Jev (`typesafe/jev-latest`) on `/v1/systemone` to classify whether a Studio
  chat message is:
  - `"switch_model"` (switching the active Gemini model / reasoning effort, e.g. `"use argon low"`),
  - `"ask_question_or_meta"` (asking a question or diagnosis in chat without changing the UI), or
  - `"build_or_modify_ui"` (creating or updating the OpenUI dashboard),
  and extracts any requested `target_model` and `reasoning_effort`.
  """
  @spec classify_chat_intent(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify_chat_intent(user_prompt, app_context \\ %{}, opts \\ [])
      when is_binary(user_prompt) do
    questions = %{
      "intent" => %{
        "type" => "choice",
        "instructions" =>
          "Classify whether the user's chat message is creating a brand-new separate app, switching the active LLM model, asking a question/meta-inquiry, OR modifying/updating the current visual UI.",
        "criteria" => %{
          "create_new_app" =>
            "The user wants to create, make, start, or add a NEW separate app/dashboard/UI with its own chat (e.g. 'make new app', 'create a new app', 'new app', 'make a new app for llm metrics', 'create a new dashboard for...').",
          "switch_model" =>
            "The user is only asking to switch, change, or select the active LLM model or reasoning/thinking effort (e.g. 'use argon low', 'switch to gemini 3.1 pro', 'use 3.8 flash', 'use 2.5 flash lite', 'use argon high') without asking another question or requesting a UI layout change in the same message.",
          "ask_question_or_meta" =>
            "The user is asking a question or seeking an explanation (e.g. 'how does the realtime stuff work?', 'did we write a parser or use gemini?', 'what variables are bound?', 'why is slab 1 high?', 'what model are we using?', 'do we have telemetry for llm calls?') without requesting a change to the UI layout or components.",
          "build_or_modify_ui" =>
            "The user wants to modify, update, add, remove, redesign, style, or wire components, live streams, alerts, or interactive controls in the CURRENT UI (e.g. 'make the UI live', 'make the operational summary section look pretty', 'add a warning alert')."
        }
      },
      "target_model" => %{
        "type" => "choice",
        "instructions" =>
          "Identify if the user requested switching to or using a specific Gemini model.",
        "criteria" => %{
          "keep_current" => "The user did not ask to switch or select a specific model.",
          "gemini-4-argon" =>
            "User asked for Argon, Gemini 4, or Gemini 4 Argon (e.g. 'argon', 'use argon low', 'gemini 4', 'gemini-4-argon').",
          "gemini-3.8-flash" =>
            "User asked for Gemini 3.8 Flash or 3.8 (e.g. '3.8 flash', 'gemini 3.8', 'default model').",
          "gemini-3.7-flash" => "User asked for Gemini 3.7 Flash or 3.7.",
          "gemini-3.6-flash" => "User asked for Gemini 3.6 Flash or 3.6.",
          "gemini-3.5-flash" => "User asked for Gemini 3.5 Flash (non-lite).",
          "gemini-3.5-flash-lite" => "User asked for Gemini 3.5 Flash Lite or 3.5 lite.",
          "gemini-3.1-pro" => "User asked for Gemini 3.1 Pro or 3.1.",
          "gemini-3.1-flash-lite" => "User asked for Gemini 3.1 Flash Lite.",
          "gemini-2.5-pro" => "User asked for Gemini 2.5 Pro.",
          "gemini-2.5-flash" => "User asked for Gemini 2.5 Flash (non-lite).",
          "gemini-2.5-flash-lite" => "User asked for Gemini 2.5 Flash Lite or 2.5 lite."
        }
      },
      "reasoning_effort" => %{
        "type" => "choice",
        "instructions" =>
          "Identify if the user specified a thinking or reasoning effort level (such as 'low', 'medium', or 'high', e.g. 'use argon low').",
        "criteria" => %{
          "default" => "No specific thinking or reasoning effort level was requested.",
          "low" =>
            "User requested 'low' effort / thinking (e.g. 'use argon low', 'low thinking').",
          "medium" => "User requested 'medium' effort / thinking (e.g. 'argon medium').",
          "high" =>
            "User requested 'high' effort / thinking (e.g. 'argon high', 'high thinking')."
        }
      },
      "topic" => %{
        "type" => "choice",
        "instructions" => "Identify the primary focus topic of the user's message.",
        "criteria" => %{
          "data_plane_and_parsers" =>
            "How real-time polling, StreamSource, Memcached/BEAM/CLI parsers, or Bind work",
          "ui_code_and_components" =>
            "OpenUI Lang DSL statements, visual widgets, or interactive Form controls",
          "live_metrics_analysis" =>
            "Inspecting or diagnosing live telemetry numbers, slabs, latency, or health",
          "studio_usage_and_meta" =>
            "How to use OpenUI Studio, model selection, chat capabilities, keyboard shortcuts, or architecture"
        }
      }
    }

    state_payload = Map.put(app_context, "user_message", user_prompt)

    with {:ok, res} <- jev_decision(state_payload, questions, opts) do
      answers = Map.get(res.body, "answers", %{})

      classification = %{
        intent: get_in(answers, ["intent", "choice"]) || "build_or_modify_ui",
        intent_confidence: get_in(answers, ["intent", "confidence"]) || 1.0,
        target_model: get_in(answers, ["target_model", "choice"]) || "keep_current",
        reasoning_effort: get_in(answers, ["reasoning_effort", "choice"]) || "default",
        topic: get_in(answers, ["topic", "choice"]) || "ui_code_and_components",
        cache_status: res.cache_status,
        prompt_tokens: Map.get(res, :prompt_tokens, 0),
        completion_tokens: Map.get(res, :completion_tokens, 0),
        total_tokens: Map.get(res, :total_tokens, 0),
        raw_cost_usd: res.raw_cost_usd,
        effective_cost_usd: 0.0,
        duration_ms: res.duration_ms
      }

      {:ok, classification}
    end
  end

  @doc """
  Answers a meta, architectural, or live-metrics question in OpenUI Studio Chat without
  overwriting or mutating the active App's `openui_code`.
  """
  @spec answer_studio_question(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def answer_studio_question(user_prompt, studio_context \\ %{}, opts \\ [])
      when is_binary(user_prompt) do
    model = Keyword.get(opts, :model, Config.default_model())
    tags = resolve_tags(opts)
    temperature = Keyword.get(opts, :temperature, 0.0)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)

    sys_prompt = """
    You are the OpenUI Studio Architecture & Live Telemetry Assistant.
     TypeSafe Jev classified the user's message as a QUESTION / META INQUIRY (`ask_question_or_meta`), so you are answering their question directly in Chat WITHOUT overwriting their UI.

    Ground-Truth Architecture of OpenUI Studio (`openui_tui` + `openui_lang`):
    1. Two-Loop Real-Time Architecture (Zero LLM Tokens in the 1Hz Loop!):
       - Loop 1 (LLM Control Plane — runs ONLY once when building/updating a UI):
         * TypeSafe Jev (`typesafe/jev-latest` on `/v1/systemone`) classifies chat intent (`ask_question_or_meta` vs `build_or_modify_ui`) and dashboard archetype in ~190ms at $0.00 effective cost.
         * Gemini (`gemini-3.8-flash`) generates or patches the declarative `openui-lang` DSL (`root = Dashboard(...)`, `StreamSource(...)`, `Bind(...)`, `Form(...)`).
       - Loop 2 (BEAM Native Data Plane — runs every 1000ms at 1Hz in Elixir with 0 LLM calls):
         * Gemini is NEVER called to parse or extract metric values during live polling!
         * Dedicated Memcached Parser (`OpenUITUI.Memcached.Probe` in `lib/openui_tui/memcached_probe.ex`):
           Connects over raw `:gen_tcp` to `127.0.0.1:11211` every 1s, sends `stats\\r\\nstats slabs\\r\\nstats items\\r\\n`, and parses `STAT <key> <value>` lines in pure Elixir. It computes per-second rate deltas (`$live_ops_sec`, `$live_ops_delta`), 18-point ring-buffer sparklines (`$live_ops_history`, `$live_hit_history`), per-slab saturation (`$live_slab_bars`), and table rows (`$live_slab_rows`, `$live_uptime_footer`).
         * Generic Source Normalizer (`OpenUITUI.SourceNormalizer` in `lib/openui_tui/source_normalizer.ex`):
           Executes allowlisted `"beam"` probes (`erlang:memory`, `recon:proc_count_memory`), `"exec"` CLI commands (`vmstat`, `free`, `df`, `uptime`, `ps`), or `"tcp"` probes and normalizes their output into maps using deterministic Elixir parsers (`"columns"` whitespace table parser, `"kv"` parser, `"json"` parser).
         * Reactive Binding Engine (`OpenUITUI.BindingEngine` in `lib/openui_tui/binding_engine.ex`):
           Evaluates `Bind($var, source_id, field, transform, template)` (`"value"`, `"rate"`, `"spark_value"`, `"spark_rate"`, `"rows"`, `"bars"`) on every 1Hz tick inside `OpenUITUI.LiveSession` (`lib/openui_tui/live_session.ex`).
    2. How to Inspect This in the TUI:
       - Press `F4` (`[F4:Code]`) to inspect the current UI's `openui-lang` DSL, active 1Hz Elixir parser pipeline, and live extracted `$live_*` / `$state` values.
       - Press `F3` (`[F3:Split]`) for side-by-side Chat + Live UI.

     Answer concisely (2–5 short bullet points or sentences) using the active UI context below. Do NOT emit a ```openui code block unless the user asked for an example snippet.
    """

    user_msg = """
    Active UI Context:
    - Title: #{Map.get(studio_context, :title, "Unknown")} (v#{Map.get(studio_context, :revision, 1)})
    - Active 1Hz StreamSources: #{inspect(Map.get(studio_context, :live_sources, []))} (tick ##{Map.get(studio_context, :live_tick, 0)})
    - Current Polled Live Bindings: #{Jason.encode!(Map.get(studio_context, :live_bindings, %{}))}
    - Current User $state: #{Jason.encode!(Map.get(studio_context, :ui_state, %{}))}
    - Current OpenUI Code:
    #{Map.get(studio_context, :openui_code, "")}

    User Question:
    #{user_prompt}
    """

    messages = [
      %{"role" => "system", "content" => sys_prompt},
      %{"role" => "user", "content" => user_msg}
    ]

    chat_completion(messages,
      model: model,
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      temperature: temperature,
      max_tokens: max_tokens,
      program_version: tags.program_version,
      prompt_version: tags.prompt_version,
      experiment_tag: tags.experiment_tag,
      bypass_cache: Keyword.get(opts, :bypass_cache, false)
    )
  end

  @doc """
  Executes a TypeSafe Jev `/v1/systemone` judgment request through LiteLLM with
  L1/L2 caching and JSONL telemetry.
  """
  @spec jev_decision(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def jev_decision(state_map, questions_map, opts \\ []) do
    model = Keyword.get(opts, :jev_model, Config.jev_model())
    tags = resolve_tags(opts)
    bypass_cache? = Keyword.get(opts, :bypass_cache, false)

    payload = %{
      "model" => model,
      "state" => state_map,
      "questions" => questions_map
    }

    prompt_hash = Telemetry.fingerprint(Jason.encode!(questions_map))

    cache_key =
      Cache.build_key("/v1/systemone", model, payload,
        prompt_version: tags.prompt_version,
        temperature: 0.0
      )

    case maybe_fetch_cache(cache_key, bypass_cache?, Map.put(tags, :model, model)) do
      {:hit, tier, cached_entry} ->
        SpendGuard.record_cache_saving(0.0, cached_entry.raw_cost_usd)

        emit_api_telemetry(
          [:openui_tui, :jev, :call],
          cached_entry,
          "hit_#{tier}",
          prompt_hash,
          tags
        )

        {:ok, Map.put(cached_entry, :cache_status, "hit_#{tier}")}

      :miss ->
        t0 = System.monotonic_time(:millisecond)
        url = Config.litellm_url() <> "/v1/systemone"

        case Req.post(url,
               headers: [
                 {"authorization", "Bearer #{Config.api_key()}"},
                 {"content-type", "application/json"}
               ],
               json: payload,
               receive_timeout: 15_000
             ) do
          {:ok, %Req.Response{status: 200, headers: headers, body: body}} ->
            duration_ms = System.monotonic_time(:millisecond) - t0
            raw_cost = parse_float_header(headers, "x-litellm-response-cost", 0.0)
            remote_spend = parse_float_header(headers, "x-litellm-key-spend", nil)
            call_id = get_header(headers, "x-litellm-call-id")

            usage = Map.get(body, "usage", %{})
            prompt_tokens = Map.get(usage, "input_tokens", 0)
            completion_tokens = Map.get(usage, "output_tokens", 0)

            entry = %{
              model: model,
              endpoint: "/v1/systemone",
              call_id: call_id,
              body: body,
              prompt_tokens: prompt_tokens,
              completion_tokens: completion_tokens,
              total_tokens: prompt_tokens + completion_tokens,
              raw_cost_usd: raw_cost,
              effective_cost_usd: 0.0,
              remote_key_spend_usd: remote_spend,
              duration_ms: duration_ms,
              cache_status: "miss"
            }

            _ = SpendGuard.record_call(entry)
            :ok = Cache.put(cache_key, entry)
            emit_api_telemetry([:openui_tui, :jev, :call], entry, "miss", prompt_hash, tags)
            {:ok, entry}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Generates OpenUI Lang code from a natural language prompt using LiteLLM
  (`gemini-2.5-flash-lite` or `gemini-3.5-flash-lite` by default), backed by
  `Cachex` (L1) + `Memcached` (L2) and `$1.00` `SpendGuard` enforcement.
  """
  @spec generate_openui(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_openui(user_prompt, opts \\ []) when is_binary(user_prompt) do
    model = Keyword.get(opts, :model, Config.default_model())
    tags = resolve_tags(opts)
    temperature = Keyword.get(opts, :temperature, 0.0)
    max_tokens = Keyword.get(opts, :max_tokens, 8192)
    use_jev_router? = Keyword.get(opts, :use_jev_router, true)

    jev_routing =
      if use_jev_router? do
        case route_tui_request(user_prompt, opts) do
          {:ok, r} -> r
          _ -> %{}
        end
      else
        %{}
      end

    {sys_prompt, prompt_hash} = Catalog.system_prompt(tags.prompt_version, jev_routing)

    messages = [
      %{"role" => "system", "content" => sys_prompt},
      %{"role" => "user", "content" => user_prompt}
    ]

    with {:ok, resp} <-
           chat_completion(messages,
             model: model,
             reasoning_effort: Keyword.get(opts, :reasoning_effort),
             temperature: temperature,
             max_tokens: max_tokens,
             prompt_hash: prompt_hash,
             program_version: tags.program_version,
             prompt_version: tags.prompt_version,
             experiment_tag: tags.experiment_tag,
             bypass_cache: Keyword.get(opts, :bypass_cache, false)
           ) do
      {:ok, Map.put(resp, :jev_routing, jev_routing)}
    end
  end

  @doc """
  Executes an OpenAI-compatible `/v1/chat/completions` request against LiteLLM
  with L1/L2 caching, `$1.00` budget gating, and JSONL telemetry.
  """
  @spec chat_completion([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat_completion(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, Config.default_model())
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    temperature = Keyword.get(opts, :temperature, 0.0)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    bypass_cache? = Keyword.get(opts, :bypass_cache, false)
    tags = resolve_tags(opts)

    prompt_hash =
      Keyword.get_lazy(opts, :prompt_hash, fn ->
        sys = Enum.find(messages, %{}, &(&1["role"] == "system"))
        Telemetry.fingerprint(Map.get(sys, "content", ""))
      end)

    base_payload = %{
      "model" => model,
      "messages" => messages,
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }

    payload =
      if reasoning_effort in ["low", "medium", "high"] do
        Map.put(base_payload, "reasoning_effort", reasoning_effort)
      else
        base_payload
      end

    cache_key =
      Cache.build_key("/v1/chat/completions", model, payload,
        prompt_version: tags.prompt_version,
        temperature: temperature
      )

    case maybe_fetch_cache(cache_key, bypass_cache?, Map.put(tags, :model, model)) do
      {:hit, tier, cached_entry} ->
        SpendGuard.record_cache_saving(
          cached_entry.effective_cost_usd,
          cached_entry.raw_cost_usd
        )

        emit_api_telemetry(
          [:openui_tui, :llm, :call],
          cached_entry,
          "hit_#{tier}",
          prompt_hash,
          tags
        )

        {:ok, Map.put(cached_entry, :cache_status, "hit_#{tier}")}

      :miss ->
        case SpendGuard.check_budget(model, opts) do
          {:error, {:budget_exceeded, report}} ->
            {:error, {:budget_exceeded, report}}

          :ok ->
            do_live_chat_completion(url_chat(), payload, model, cache_key, prompt_hash, tags)
        end
    end
  end

  defp do_live_chat_completion(url, payload, model, cache_key, prompt_hash, tags) do
    t0 = System.monotonic_time(:millisecond)

    case Req.post(url,
           headers: [
             {"authorization", "Bearer #{Config.api_key()}"},
             {"content-type", "application/json"}
           ],
           json: payload,
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: 200, headers: headers, body: body}} ->
        duration_ms = System.monotonic_time(:millisecond) - t0
        raw_cost = parse_float_header(headers, "x-litellm-response-cost", 0.0)
        remote_spend = parse_float_header(headers, "x-litellm-key-spend", nil)
        call_id = get_header(headers, "x-litellm-call-id")
        eff_cost = if Config.jev_model?(model), do: 0.0, else: raw_cost

        usage = Map.get(body, "usage", %{})
        prompt_tokens = Map.get(usage, "prompt_tokens", 0)
        completion_tokens = Map.get(usage, "completion_tokens", 0)
        total_tokens = Map.get(usage, "total_tokens", prompt_tokens + completion_tokens)

        content =
          body
          |> Map.get("choices", [])
          |> List.first(%{})
          |> get_in(["message", "content"]) || ""

        entry = %{
          model: model,
          endpoint: "/v1/chat/completions",
          call_id: call_id,
          content: String.trim(content),
          body: body,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          total_tokens: total_tokens,
          raw_cost_usd: raw_cost,
          effective_cost_usd: eff_cost,
          remote_key_spend_usd: remote_spend,
          duration_ms: duration_ms,
          cache_status: "miss"
        }

        :ok = Cache.put(cache_key, entry)
        emit_api_telemetry([:openui_tui, :llm, :call], entry, "miss", prompt_hash, tags)

        case SpendGuard.record_call(entry) do
          {:ok, _ledger} ->
            {:ok, entry}

          {:budget_exceeded, report} ->
            {:ok, Map.put(entry, :budget_warning_report, report)}
        end

      {:ok, %Req.Response{status: status, body: body}} when status in [400, 429] ->
        body_str = inspect(body)

        if String.contains?(body_str, "BudgetExceeded") or String.contains?(body_str, "budget") do
          report =
            OpenUITUI.SpendReport.generate_and_save!(%{
              attempted_model: model,
              trigger_reason: "litellm_proxy_budget_exceeded_http_#{status}"
            })

          {:error, {:budget_exceeded, report}}
        else
          {:error, {:http_error, status, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_fetch_cache(_cache_key, true = _bypass, _meta), do: :miss
  defp maybe_fetch_cache(cache_key, false, meta), do: Cache.fetch(cache_key, meta)

  defp emit_api_telemetry(event_name, entry, cache_status, prompt_hash, tags) do
    is_cached? = cache_status in ["hit_l1_cachex", "hit_l2_memcached"]

    :telemetry.execute(
      event_name,
      %{
        duration_ms: if(is_cached?, do: 0.1, else: entry.duration_ms * 1.0),
        prompt_tokens: entry.prompt_tokens,
        completion_tokens: entry.completion_tokens,
        total_tokens: entry.total_tokens,
        raw_cost_usd: if(is_cached?, do: 0.0, else: entry.raw_cost_usd),
        effective_cost_usd: if(is_cached?, do: 0.0, else: entry.effective_cost_usd),
        saved_cost_usd: if(is_cached?, do: entry.effective_cost_usd, else: 0.0),
        saved_raw_cost_usd: if(is_cached?, do: entry.raw_cost_usd, else: 0.0)
      },
      %{
        model: entry.model,
        endpoint: entry.endpoint,
        call_id: entry.call_id,
        cache_status: cache_status,
        prompt_hash: prompt_hash,
        schema_hash: Catalog.schema_hash(),
        program_version: tags.program_version,
        prompt_version: tags.prompt_version,
        experiment_tag: tags.experiment_tag
      }
    )
  end

  defp resolve_tags(opts) do
    base =
      case Process.whereis(Telemetry) do
        nil ->
          %{
            program_version: Config.program_version(),
            prompt_version: Config.prompt_version(),
            experiment_tag: Config.experiment_tag()
          }

        _pid ->
          Telemetry.current_tags()
      end

    %{
      program_version: Keyword.get(opts, :program_version, base.program_version),
      prompt_version: Keyword.get(opts, :prompt_version, base.prompt_version),
      experiment_tag: Keyword.get(opts, :experiment_tag, base.experiment_tag)
    }
  end

  defp url_chat, do: Config.litellm_url() <> "/v1/chat/completions"

  defp get_header(headers, key) when is_map(headers) do
    case Map.get(headers, key) || Map.get(headers, String.downcase(key)) do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp get_header(headers, key) when is_list(headers) do
    target = String.downcase(key)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == target do
        if is_list(v), do: List.first(v), else: to_string(v)
      end
    end)
  end

  defp parse_float_header(headers, key, default) do
    case get_header(headers, key) do
      nil ->
        default

      str when is_binary(str) ->
        case Float.parse(String.trim(str)) do
          {v, _} -> v
          :error -> default
        end
    end
  end
end
