defmodule OpenUITUI.Memcached do
  @moduledoc """
  Lightweight, zero-warning Erlang `:gen_tcp` client for the local `memcached`
  daemon (`127.0.0.1:11211`).

  Used as the persistent L2 cache tier behind `Cachex` (L1) so LLM and TypeSafe
  Jev responses survive across Mix commands, test runs, and VM restarts without
  re-spending tokens.
  """

  alias OpenUITUI.Config

  @prefix "openui_tui:v1:"
  @timeout 1_500

  @doc """
  Checks if the local `memcached` server is reachable and returns its version string.
  """
  @spec ping() :: {:ok, String.t()} | {:error, term()}
  def ping do
    with {:ok, sock} <- connect(),
         :ok <- :gen_tcp.send(sock, "version\r\n"),
         {:ok, line} <- :gen_tcp.recv(sock, 0, @timeout) do
      :gen_tcp.close(sock)

      case String.trim(line) do
        "VERSION " <> ver -> {:ok, ver}
        other -> {:ok, other}
      end
    end
  end

  @doc """
  Fetches a decoded Elixir term by key from `memcached`.
  """
  @spec get(String.t()) :: {:ok, term()} | :miss | {:error, term()}
  def get(key) when is_binary(key) do
    full_key = normalize_key(key)

    with {:ok, sock} <- connect(),
         :ok <- :gen_tcp.send(sock, "get #{full_key}\r\n"),
         {:ok, header} <- :gen_tcp.recv(sock, 0, @timeout) do
      result =
        case String.trim(header) do
          "END" ->
            :miss

          "VALUE " <> rest ->
            case String.split(rest, " ") do
              [_k, _flags, bytes_str | _] ->
                {bytes, _} = Integer.parse(bytes_str)
                # Switch to raw mode to read exact payload + \r\n + END\r\n
                :inet.setopts(sock, packet: :raw)

                with {:ok, payload} <- :gen_tcp.recv(sock, bytes, @timeout),
                     {:ok, _crlf} <- :gen_tcp.recv(sock, 2, @timeout),
                     {:ok, _end} <- :gen_tcp.recv(sock, 5, @timeout) do
                  decode_term(payload)
                end

              _ ->
                :miss
            end

          _ ->
            :miss
        end

      :gen_tcp.close(sock)
      result
    end
  end

  @doc """
  Stores an Elixir term in `memcached` with the given TTL in seconds (default 86,400s / 24h).
  """
  @spec set(String.t(), term(), non_neg_integer()) :: :ok | {:error, term()}
  def set(key, value, ttl_seconds \\ 86_400) when is_binary(key) do
    full_key = normalize_key(key)
    payload = encode_term(value)
    byte_len = byte_size(payload)

    with {:ok, sock} <- connect(),
         :ok <-
           :gen_tcp.send(sock, [
             "set #{full_key} 0 #{ttl_seconds} #{byte_len}\r\n",
             payload,
             "\r\n"
           ]),
         {:ok, reply} <- :gen_tcp.recv(sock, 0, @timeout) do
      :gen_tcp.close(sock)

      case String.trim(reply) do
        "STORED" -> :ok
        other -> {:error, {:unexpected_reply, other}}
      end
    end
  end

  @doc """
  Deletes a key from `memcached`.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    full_key = normalize_key(key)

    with {:ok, sock} <- connect(),
         :ok <- :gen_tcp.send(sock, "delete #{full_key}\r\n"),
         {:ok, _reply} <- :gen_tcp.recv(sock, 0, @timeout) do
      :gen_tcp.close(sock)
      :ok
    end
  end

  defp connect do
    :gen_tcp.connect(
      Config.memcached_host(),
      Config.memcached_port(),
      [:binary, active: false, packet: :line],
      @timeout
    )
  end

  defp normalize_key(key) do
    # Memcached keys must be <= 250 bytes and contain no whitespace
    hash =
      :crypto.hash(:sha256, key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    @prefix <> hash
  end

  defp encode_term(value) do
    value
    |> :erlang.term_to_binary([:compressed])
    |> Base.encode64()
  end

  defp decode_term(payload) do
    with {:ok, bin} <- Base.decode64(String.trim(payload)) do
      {:ok, :erlang.binary_to_term(bin)}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end
end
