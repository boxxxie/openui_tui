defmodule OpenUITUI.SourceNormalizer do
  @moduledoc """
  Executes allowlisted local commands (`vmstat`, `ps`, `df`, `free`, `uptime`,
  `iostat`, `docker`, `redis-cli`), TCP probes (`127.0.0.1:11211|stats\\r\\n`),
  or BEAM introspection calls (`erlang:memory`, `recon:proc_count_memory`,
  `recon:proc_count_reductions`) and normalizes their output into a uniform list
  of string-keyed maps (`[%{String.t() => number() | String.t()}]`).

  ## Security & BEAM Safety Guarantees
  1. **No Shell Execution (`sh -c`)**: `"exec"` tokenizes arguments via `OptionParser.split/1`
     and validates the executable against `@allowed_bins` before calling `System.cmd/3`.
  2. **No Dynamic `String.to_atom/1`**: `"beam"` dispatches against explicit binary probe names.
  3. **Sub-Binary Copy**: Copies extracted keys/values with `:binary.copy/1`.
  """

  @allowed_bins ~w(vmstat ps df free uptime iostat docker redis-cli)

  @type row_map :: %{optional(String.t()) => String.t() | number()}

  @doc """
  Fetches and normalizes output from `"exec"`, `"tcp"`, or `"beam"` transports.
  """
  @spec fetch_and_normalize(String.t(), String.t(), String.t()) ::
          {:ok, [row_map()]} | {:error, term()}
  def fetch_and_normalize("exec", command_str, format) do
    with {:ok, bin, args} <- validate_command(command_str),
         {output, 0} <- System.cmd(bin, args, stderr_to_stdout: true) do
      {:ok, parse_format(format, output)}
    else
      {_output, exit_code} when is_integer(exit_code) -> {:error, {:exit_code, exit_code}}
      {:error, _} = err -> err
    end
  end

  def fetch_and_normalize("tcp", target_spec, format) do
    # target_spec format: "127.0.0.1:11211|stats\r\n" or "127.0.0.1:11211"
    {addr, payload} =
      case String.split(target_spec, "|", parts: 2) do
        [a, p] -> {a, p}
        [a] -> {a, "stats\r\n"}
      end

    with [host, port_str] <- String.split(addr, ":", parts: 2),
         {port, ""} <- Integer.parse(port_str),
         {:ok, sock} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_500),
         :ok <- :gen_tcp.send(sock, String.replace(payload, "\\r\\n", "\r\n")),
         {:ok, raw} <- recv_all_tcp(sock, []) do
      :gen_tcp.close(sock)
      {:ok, parse_format(format, IO.iodata_to_binary(raw))}
    else
      _ -> {:error, :tcp_probe_failed}
    end
  end

  def fetch_and_normalize("beam", probe_name, _format) do
    {:ok, run_beam_probe(probe_name)}
  end

  def fetch_and_normalize(_transport, _target, _format), do: {:error, :unsupported_transport}

  @doc """
  Pre-flight read-only tool for LLM agents: runs `fetch_and_normalize/3` once and
  returns `%{row_count, available_keys, sample_row}` so the LLM knows exact column
  names before emitting `StreamSource(...)` and `Bind(...)` statements.
  """
  @spec inspect_metric_source(String.t(), String.t(), String.t()) :: map()
  def inspect_metric_source(transport, target, format) do
    case fetch_and_normalize(transport, target, format) do
      {:ok, [sample_row | _] = rows} ->
        %{
          row_count: length(rows),
          available_keys: Map.keys(sample_row) |> Enum.sort(),
          sample_row: sample_row
        }

      {:ok, []} ->
        %{error: "Source returned 0 rows"}

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # 1. FORMAT PARSERS ("columns", "json", "kv")
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes raw text output into `[%{String.t() => number() | String.t()}]`.
  """
  @spec parse_format(String.t(), String.t()) :: [row_map()]
  def parse_format("columns", raw_text) do
    lines =
      raw_text
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case drop_decorative_banners(lines) do
      [header_line | data_lines] ->
        headers = String.split(header_line, ~r/\s+/, trim: true)

        Enum.map(data_lines, fn line ->
          cols = String.split(line, ~r/\s+/, trim: true)

          headers
          |> Enum.zip(cols)
          |> Map.new(fn {k, v} -> {:binary.copy(k), coerce_scalar(:binary.copy(v))} end)
        end)

      _ ->
        []
    end
  end

  def parse_format("json", raw_text) do
    trimmed = String.trim(raw_text)

    decoded =
      if String.starts_with?(trimmed, "[") do
        case Jason.decode(trimmed) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      else
        trimmed
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} when is_map(map) -> [map]
            _ -> []
          end
        end)
      end

    Enum.map(List.wrap(decoded), fn map ->
      Map.new(map, fn {k, v} ->
        {:binary.copy(to_string(k)), coerce_scalar(v)}
      end)
    end)
  end

  def parse_format("kv", raw_text) do
    kv_map =
      raw_text
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        clean = line |> String.trim() |> String.trim_leading("STAT ")

        case String.split(clean, ~r/[:\s]+/, parts: 2) do
          [k, v] when k not in ["END", "OK", "#"] ->
            Map.put(acc, :binary.copy(k), coerce_scalar(:binary.copy(String.trim(v))))

          _ ->
            acc
        end
      end)

    [kv_map]
  end

  def parse_format(_other, _raw), do: []

  # ---------------------------------------------------------------------------
  # 2. ALLOWLISTED BEAM VM & :recon PROBES
  # ---------------------------------------------------------------------------

  defp run_beam_probe("erlang:memory") do
    mem = :erlang.memory()

    [
      %{
        "total_mb" => Float.round(mem[:total] / 1_048_576, 1),
        "processes_mb" => Float.round(mem[:processes] / 1_048_576, 1),
        "binary_mb" => Float.round(mem[:binary] / 1_048_576, 1),
        "ets_mb" => Float.round(mem[:ets] / 1_048_576, 1),
        "atom_mb" => Float.round(mem[:atom] / 1_048_576, 2),
        "run_queue" => :erlang.statistics(:run_queue),
        "process_count" => :erlang.system_info(:process_count)
      }
    ]
  end

  defp run_beam_probe("recon:proc_count_memory") do
    top_beam_processes(:memory)
  end

  defp run_beam_probe("recon:proc_count_reductions") do
    top_beam_processes(:reductions)
  end

  defp run_beam_probe(_unknown), do: []

  defp top_beam_processes(attr) do
    raw_list =
      if Code.ensure_loaded?(:recon) do
        apply(:recon, :proc_count, [attr, 6])
      else
        Process.list()
        |> Enum.map(fn pid ->
          info = Process.info(pid, [:registered_name, :memory, :reductions]) || []
          {pid, info[attr] || 0, info}
        end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(6)
      end

    Enum.map(raw_list, fn {pid, _val, info_or_meta} ->
      info =
        if is_list(info_or_meta),
          do: info_or_meta,
          else: Process.info(pid, [:registered_name, :memory, :reductions]) || []

      reg_name =
        case Keyword.get(info, :registered_name) do
          name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
          _ -> inspect(pid)
        end

      mem_bytes = Keyword.get(info, :memory, 0)
      reds = Keyword.get(info, :reductions, 0)

      %{
        "pid" => inspect(pid),
        "name" => reg_name,
        "memory_kb" => "#{Float.round(mem_bytes / 1024, 1)} KB",
        "reductions" => to_string(reds)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # INTERNAL HELPERS
  # ---------------------------------------------------------------------------

  defp validate_command(cmd_str) do
    case OptionParser.split(cmd_str) do
      [bin | args] when bin in @allowed_bins ->
        case System.find_executable(bin) do
          nil -> {:error, {:executable_not_found, bin}}
          path -> {:ok, path, args}
        end

      [bin | _] ->
        {:error, {:command_not_allowlisted, bin}}

      [] ->
        {:error, :empty_command}
    end
  end

  defp drop_decorative_banners([first, second | rest] = lines) do
    if String.contains?(first, "---") or String.starts_with?(first, "procs ") do
      [second | rest]
    else
      lines
    end
  end

  defp drop_decorative_banners(lines), do: lines

  defp recv_all_tcp(sock, acc) do
    case :gen_tcp.recv(sock, 0, 400) do
      {:ok, chunk} ->
        if String.contains?(chunk, "END\r\n") do
          {:ok, Enum.reverse([chunk | acc])}
        else
          recv_all_tcp(sock, [chunk | acc])
        end

      {:error, :timeout} when acc != [] ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Coerces strings like `"68.4%"`, `"42"`, or `"14.2"` into numbers when appropriate,
  so sparklines and BarLists can plot CLI percentage columns directly.
  """
  @spec coerce_scalar(term()) :: number() | String.t()
  def coerce_scalar(v) when is_number(v), do: v

  def coerce_scalar(v) when is_binary(v) do
    clean = String.trim_trailing(v, "%")

    case Integer.parse(clean) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(clean) do
          {f, ""} -> f
          _ -> v
        end
    end
  end

  def coerce_scalar(v), do: to_string(v)
end
