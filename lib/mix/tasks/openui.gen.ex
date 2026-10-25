defmodule Mix.Tasks.Openui.Gen do
  @moduledoc """
  Generates an OpenUI Lang Terminal UI from a natural language prompt using LiteLLM.

  ## Examples

      mix openui.gen "Show me postgres cluster health with replication lag and disk stats"
      mix openui.gen "Hetzner fleet status" --renderer owl
      mix openui.gen "Redis memory monitor" --compare
      mix openui.gen "Kubernetes pods" --code-only
  """
  use Mix.Task

  @shortdoc "Generates a Terminal UI from an English prompt via LLM"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          renderer: :string,
          model: :string,
          code_only: :boolean,
          compare: :boolean,
          no_jev: :boolean
        ],
        aliases: [
          r: :renderer,
          m: :model,
          c: :compare
        ]
      )

    prompt = Enum.join(argv, " ")

    if String.trim(prompt) == "" do
      IO.puts(
        IO.ANSI.red() <>
          "Error: Please provide a prompt. Example: mix openui.gen \"Hetzner server status\"" <>
          IO.ANSI.reset()
      )

      System.halt(1)
    end

    renderer =
      case Keyword.get(opts, :renderer, "fixed_80") do
        "80" -> :fixed_80
        "fixed_80" -> :fixed_80
        "owl" -> :owl
        "pure_ansi" -> :pure_ansi
        "table_rex" -> :table_rex
        "compact_ops" -> :compact_ops
        _ -> :fixed_80
      end

    model = Keyword.get(opts, :model, OpenUITUI.Config.default_model())
    use_jev = not Keyword.get(opts, :no_jev, false)

    case OpenUITUI.generate_tui(prompt, model: model, use_jev_router: use_jev) do
      {:ok, result} ->
        if Keyword.get(opts, :code_only, false) do
          IO.puts(result.openui_code)
        else
          IO.puts(
            "\n" <>
              IO.ANSI.bright() <>
              IO.ANSI.cyan() <> "═══ OpenUI TUI Generator ═══" <> IO.ANSI.reset()
          )

          IO.puts("• Model:       #{result.model}")
          IO.puts("• Cache:       #{result.cache_status}")

          IO.puts(
            "• Tokens:      #{result.prompt_tokens} prompt / #{result.completion_tokens} completion"
          )

          IO.puts(
            "• Billed Spend: $#{:erlang.float_to_binary(result.effective_cost_usd, decimals: 6)}"
          )

          IO.puts(
            "• Compression: #{result.openui_bytes}B OpenUI vs #{result.equivalent_json_bytes}B JSON (#{result.compression_savings_pct}% token saving)"
          )

          if result.jev_routing do
            IO.puts(
              "• Jev Router:  archetype=#{result.jev_routing.archetype} | recommended=#{result.jev_routing.recommended_renderer}"
            )
          end

          IO.puts(
            "\n" <> IO.ANSI.bright() <> "── Generated OpenUI Lang DSL ──" <> IO.ANSI.reset()
          )

          IO.puts(IO.ANSI.yellow() <> result.openui_code <> IO.ANSI.reset())

          if Keyword.get(opts, :compare, false) do
            IO.puts("\n" <> IO.ANSI.bright() <> "── 5-Engine Comparison ──" <> IO.ANSI.reset())

            Enum.each([:fixed_80, :owl, :pure_ansi, :table_rex, :compact_ops], fn r_id ->
              IO.puts("\n" <> IO.ANSI.bright() <> "▶ Renderer: #{r_id}" <> IO.ANSI.reset())
              IO.puts(OpenUITUI.render(result.openui_code, r_id))
            end)
          else
            IO.puts(
              "\n" <> IO.ANSI.bright() <> "── Rendered Output (#{renderer}) ──" <> IO.ANSI.reset()
            )

            IO.puts(OpenUITUI.render(result.openui_code, renderer))
          end
        end

      {:error, {:budget_exceeded, report}} ->
        IO.puts(
          IO.ANSI.red() <>
            "\n[!] SPEND LIMIT EXCEEDED ($1.00 Budget Cap Reached) [!]" <> IO.ANSI.reset()
        )

        IO.puts("A review report was generated: #{report.report_path}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "Error generating TUI: #{inspect(reason)}" <> IO.ANSI.reset())
        System.halt(1)
    end
  end
end
