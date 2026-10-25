defmodule OpenUITUI.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :openui_tui,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description:
        "OpenUI Lang TUI Maker for Elixir: multi-renderer terminal UI generator with LiteLLM, TypeSafe Jev, Cachex + Memcached caching, spend guardrails, and versioned JSONL telemetry."
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {OpenUITUI.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:openui_lang, path: "../openui_lang"},
      {:jido, "~> 2.4"},
      {:owl, "~> 0.13.1"},
      {:table_rex, "~> 4.1"},
      {:cachex, "~> 4.0"},
      {:telemetry, "~> 1.3"},
      {:req, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
