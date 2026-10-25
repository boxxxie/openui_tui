defmodule Mix.Tasks.Openui.Render do
  @moduledoc """
  Renders an OpenUI Lang file (or standard input) with the selected TUI engine.

  ## Examples

      mix openui.render priv/examples/dashboard.oui
      mix openui.render priv/examples/dashboard.oui --renderer owl
      mix openui.render priv/examples/dashboard.oui --compare
      cat my_ui.oui | mix openui.render -
  """
  use Mix.Task

  @shortdoc "Renders an OpenUI Lang file or stdin with a TUI engine"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          renderer: :string,
          compare: :boolean
        ],
        aliases: [
          r: :renderer,
          c: :compare
        ]
      )

    source = List.first(argv)

    if is_nil(source) do
      IO.puts(
        IO.ANSI.red() <> "Error: Please provide a file path or '-' for stdin." <> IO.ANSI.reset()
      )

      System.halt(1)
    end

    code =
      if source == "-" do
        IO.read(:stdio, :all)
      else
        case File.read(source) do
          {:ok, content} ->
            content

          {:error, reason} ->
            IO.puts(
              IO.ANSI.red() <>
                "Failed to read file '#{source}': #{inspect(reason)}" <> IO.ANSI.reset()
            )

            System.halt(1)
        end
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

    if Keyword.get(opts, :compare, false) do
      IO.puts(
        "\n" <>
          IO.ANSI.bright() <>
          IO.ANSI.cyan() <> "═══ OpenUI Multi-Renderer Comparison ═══" <> IO.ANSI.reset()
      )

      Enum.each([:fixed_80, :owl, :pure_ansi, :table_rex, :compact_ops], fn r_id ->
        IO.puts("\n" <> IO.ANSI.bright() <> "▶ Renderer: #{r_id}" <> IO.ANSI.reset())
        IO.puts(OpenUITUI.render(code, r_id))
      end)
    else
      IO.puts(OpenUITUI.render(code, renderer))
    end
  end
end
