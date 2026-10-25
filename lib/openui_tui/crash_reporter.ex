defmodule OpenUITUI.CrashReporter do
  @moduledoc """
  Records structured crash reports (`priv/reports/latest_crash.md` and `priv/telemetry/crashes.jsonl`)
  whenever an unexpected exception occurs in OpenUI Studio or LLM app evolution so crashes
  are recoverable and auditable without killing the user's TUI session.
  """

  @doc """
  Returns the path to the latest Markdown crash report.
  """
  @spec latest_report_path() :: String.t()
  def latest_report_path do
    Path.expand("../../priv/reports/latest_crash.md", __DIR__)
  end

  @doc """
  Returns the path to the JSONL crash log.
  """
  @spec crashes_jsonl_path() :: String.t()
  def crashes_jsonl_path do
    Path.expand("../../priv/telemetry/crashes.jsonl", __DIR__)
  end

  @doc """
  Records an exception + stacktrace + context map into `priv/reports/latest_crash.md` and
  `priv/telemetry/crashes.jsonl`.
  """
  @spec record_exception(Exception.t() | term(), list(), map()) :: String.t()
  def record_exception(exception, stacktrace, context \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    formatted_err =
      if is_exception(exception) do
        Exception.format(:error, exception, stacktrace)
      else
        inspect(exception, pretty: true) <> "\n" <> Exception.format_stacktrace(stacktrace)
      end

    entry = %{
      "timestamp" => now,
      "error" =>
        if(is_exception(exception), do: Exception.message(exception), else: inspect(exception)),
      "context" => context,
      "stacktrace" => formatted_err
    }

    File.mkdir_p!(Path.dirname(crashes_jsonl_path()))
    File.mkdir_p!(Path.dirname(latest_report_path()))

    File.write!(crashes_jsonl_path(), Jason.encode!(entry) <> "\n", [:append])

    md = """
    # OpenUI Studio — Crash Report

    - **Timestamp:** `#{now}`
    - **Context:** `#{inspect(Map.drop(context, [:openui_code]))}`

    ## Exception & Stacktrace
    ```text
    #{String.trim(formatted_err)}
    ```
    """

    File.write!(latest_report_path(), md)
    latest_report_path()
  end
end
