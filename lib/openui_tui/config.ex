defmodule OpenUITUI.Config do
  @moduledoc """
  Centralized runtime configuration for `OpenUITUI`, including LiteLLM proxy
  connection settings, virtual key (`$1.00` spend cap), supported Gemini models
  (defaulting to `gemini-3.8-flash` and supporting `gemini-4-argon` with
  `reasoning_effort` `low`/`medium`/`high`), Memcached coordinates, and version tags.
  """

  @default_litellm_url "http://localhost:4000"
  @default_virtual_key ""
  @default_gemini_model "gemini-3.8-flash"
  @fallback_gemini_model "gemini-3.5-flash"
  @default_jev_model "typesafe/jev-latest"
  @default_budget_limit_usd 1.00
  @default_soft_budget_usd 0.80

  @supported_gemini_models [
    "gemini-3.8-flash",
    "gemini-4-argon",
    "gemini-3.1-pro",
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.1-flash-lite",
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite"
  ]

  @spec supported_gemini_models() :: [String.t()]
  def supported_gemini_models, do: @supported_gemini_models

  @spec format_model_badge(String.t() | nil, String.t() | nil) :: String.t()
  def format_model_badge(model, reasoning_effort \\ nil) do
    m = model || default_model()

    case reasoning_effort do
      eff when eff in ["low", "medium", "high"] -> "#{m} (#{eff})"
      _ -> m
    end
  end

  @spec litellm_url() :: String.t()
  def litellm_url do
    System.get_env("OPENUI_LITELLM_URL") ||
      Application.get_env(:openui_tui, :litellm_url, @default_litellm_url)
  end

  @spec api_key() :: String.t()
  def api_key do
    System.get_env("OPENUI_LITELLM_API_KEY") ||
      System.get_env("LITELLM_API_KEY") ||
      Application.get_env(:openui_tui, :api_key, @default_virtual_key)
  end

  @spec default_model() :: String.t()
  def default_model do
    System.get_env("OPENUI_DEFAULT_MODEL") ||
      Application.get_env(:openui_tui, :default_model, @default_gemini_model)
  end

  @spec fallback_model() :: String.t()
  def fallback_model, do: @fallback_gemini_model

  @spec jev_model() :: String.t()
  def jev_model do
    System.get_env("OPENUI_JEV_MODEL") ||
      Application.get_env(:openui_tui, :jev_model, @default_jev_model)
  end

  @spec budget_limit_usd() :: float()
  def budget_limit_usd do
    case System.get_env("OPENUI_BUDGET_LIMIT_USD") do
      nil ->
        Application.get_env(:openui_tui, :budget_limit_usd, @default_budget_limit_usd) * 1.0

      str ->
        case Float.parse(str) do
          {v, _} -> v
          :error -> @default_budget_limit_usd
        end
    end
  end

  @spec soft_budget_usd() :: float()
  def soft_budget_usd do
    Application.get_env(:openui_tui, :soft_budget_usd, @default_soft_budget_usd) * 1.0
  end

  @spec memcached_host() :: :inet.ip_address() | charlist()
  def memcached_host do
    Application.get_env(:openui_tui, :memcached_host, {127, 0, 0, 1})
  end

  @spec memcached_port() :: :inet.port_number()
  def memcached_port do
    Application.get_env(:openui_tui, :memcached_port, 11_211)
  end

  @spec telemetry_jsonl_path() :: String.t()
  def telemetry_jsonl_path do
    System.get_env("OPENUI_TELEMETRY_JSONL") ||
      Application.get_env(
        :openui_tui,
        :telemetry_jsonl_path,
        Path.expand("../../priv/telemetry/events.jsonl", __DIR__)
      )
  end

  @spec reports_dir() :: String.t()
  def reports_dir do
    Application.get_env(
      :openui_tui,
      :reports_dir,
      Path.expand("../../priv/reports", __DIR__)
    )
  end

  @spec program_version() :: String.t()
  def program_version do
    System.get_env("OPENUI_PROGRAM_VERSION") ||
      Application.get_env(:openui_tui, :program_version, "0.2.0")
  end

  @spec prompt_version() :: String.t()
  def prompt_version do
    System.get_env("OPENUI_PROMPT_VERSION") ||
      Application.get_env(:openui_tui, :prompt_version, "v2-compact-tui")
  end

  @spec experiment_tag() :: String.t()
  def experiment_tag do
    System.get_env("OPENUI_EXPERIMENT_TAG") ||
      Application.get_env(:openui_tui, :experiment_tag, "default")
  end

  @spec jev_model?(String.t()) :: boolean()
  def jev_model?(model) when is_binary(model) do
    String.contains?(String.downcase(model), "jev") or
      String.starts_with?(String.downcase(model), "typesafe/")
  end
end
