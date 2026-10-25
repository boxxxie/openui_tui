defmodule OpenUITUI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cachex, name: :openui_tui_cache},
      OpenUITUI.Telemetry,
      OpenUITUI.SpendGuard,
      OpenUITUI.Jido
    ]

    opts = [strategy: :one_for_one, name: OpenUITUI.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
