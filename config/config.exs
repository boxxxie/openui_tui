import Config

# Default configuration for OpenUI TUI Maker & Studio (`openui_tui`).
#
# All values here are safe public defaults and can be overridden via:
#   1. Environment variables (`OPENUI_LITELLM_URL`, `OPENUI_LITELLM_API_KEY`, etc.), or
#   2. A gitignored `config/local.secret.exs` file (copy `config/local.secret.exs.example`).

config :openui_tui,
  # Base URL of your LiteLLM Proxy or OpenAI-compatible gateway
  litellm_url: "http://localhost:4000",
  # Virtual API key for LiteLLM (leave empty here; set via env or config/local.secret.exs)
  api_key: "",
  # Default Gemini model for OpenUI generation and Studio Q&A
  default_model: "gemini-3.8-flash",
  # TypeSafe Jev SystemOne router model (`/v1/systemone`)
  jev_model: "typesafe/jev-latest",
  # Hard and soft spend guardrails (USD)
  budget_limit_usd: 1.00,
  soft_budget_usd: 0.80,
  # Local Memcached L2 cache & live telemetry probe coordinates
  memcached_host: {127, 0, 0, 1},
  memcached_port: 11_211

# Load gitignored local overrides if present
if File.exists?(Path.expand("local.secret.exs", __DIR__)) do
  import_config "local.secret.exs"
end
