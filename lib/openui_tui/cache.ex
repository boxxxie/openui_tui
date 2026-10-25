defmodule OpenUITUI.Cache do
  @moduledoc """
  Two-tier response cache combining:
  - **L1 (`Cachex`)**: In-memory ETS cache (`:openui_tui_cache`) for sub-microsecond lookups.
  - **L2 (`OpenUITUI.Memcached`)**: System `memcached` (`127.0.0.1:11211`) for persistent cross-run caching.

  Prevents duplicate LLM and TypeSafe Jev API calls from spending budget and records
  exact USD savings in telemetry whenever a cached response is served.
  """

  alias OpenUITUI.Memcached

  @cache_name :openui_tui_cache
  @default_ttl_seconds 86_400

  @doc """
  Computes a deterministic SHA-256 cache key from request parameters.
  """
  @spec build_key(String.t(), String.t(), map() | list() | String.t(), keyword()) :: String.t()
  def build_key(endpoint, model, payload, opts \\ []) do
    prompt_version = Keyword.get(opts, :prompt_version, "v1")
    temperature = Keyword.get(opts, :temperature, 0.0)

    canonical =
      :erlang.term_to_binary(%{
        endpoint: endpoint,
        model: model,
        prompt_version: prompt_version,
        temperature: temperature,
        payload: payload
      })

    hash =
      :crypto.hash(:sha256, canonical)
      |> Base.encode16(case: :lower)

    "#{endpoint}:#{model}:#{prompt_version}:#{hash}"
  end

  @doc """
  Fetches a cached entry from L1 (`Cachex`) or L2 (`Memcached`).
  If found in L2 (`Memcached`), automatically warms L1 (`Cachex`).
  Emits `[:openui_tui, :cache, :lookup]` telemetry on every call.
  """
  @spec fetch(String.t(), map()) :: {:hit, :l1_cachex | :l2_memcached, map()} | :miss
  def fetch(key, meta \\ %{}) when is_binary(key) do
    t0 = System.monotonic_time(:microsecond)

    case Cachex.get(@cache_name, key) do
      {:ok, %{} = entry} ->
        duration_us = System.monotonic_time(:microsecond) - t0
        emit_lookup(:hit_l1_cachex, key, duration_us, entry, meta)
        {:hit, :l1_cachex, entry}

      _ ->
        case Memcached.get(key) do
          {:ok, %{} = entry} ->
            _ = Cachex.put(@cache_name, key, entry, expire: :timer.seconds(@default_ttl_seconds))
            duration_us = System.monotonic_time(:microsecond) - t0
            emit_lookup(:hit_l2_memcached, key, duration_us, entry, meta)
            {:hit, :l2_memcached, entry}

          _ ->
            duration_us = System.monotonic_time(:microsecond) - t0
            emit_lookup(:miss, key, duration_us, nil, meta)
            :miss
        end
    end
  end

  @doc """
  Stores an API response entry in both L1 (`Cachex`) and L2 (`Memcached`).
  """
  @spec put(String.t(), map(), non_neg_integer()) :: :ok
  def put(key, %{} = entry, ttl_seconds \\ @default_ttl_seconds) when is_binary(key) do
    _ = Cachex.put(@cache_name, key, entry, expire: :timer.seconds(ttl_seconds))
    _ = Memcached.set(key, entry, ttl_seconds)
    :ok
  end

  @doc """
  Invalidates a cache key in both L1 (`Cachex`) and L2 (`Memcached`).
  """
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    _ = Cachex.del(@cache_name, key)
    _ = Memcached.delete(key)
    :ok
  end

  @doc """
  Clears the L1 `Cachex` table.
  """
  @spec clear_l1() :: :ok
  def clear_l1 do
    _ = Cachex.clear(@cache_name)
    :ok
  end

  defp emit_lookup(status, key, duration_us, entry, meta) do
    saved_cost = if is_map(entry), do: Map.get(entry, :effective_cost_usd, 0.0), else: 0.0
    saved_raw_cost = if is_map(entry), do: Map.get(entry, :raw_cost_usd, 0.0), else: 0.0

    :telemetry.execute(
      [:openui_tui, :cache, :lookup],
      %{
        duration_us: duration_us,
        saved_cost_usd: saved_cost,
        saved_raw_cost_usd: saved_raw_cost
      },
      Map.merge(meta, %{
        cache_key: key,
        cache_status: Atom.to_string(status)
      })
    )
  end
end
