defmodule ElixirGateway.JsonLogHandler do
  @moduledoc """
  JSON formatter for Erlang's :logger_std_h handler.
  Outputs one JSON line per log event for Grafana Alloy ingestion.
  Runs alongside the :console handler — stdout format is unchanged.

  Enable via JSON_LOG_PATH env var pointing to the shared Docker volume path.
  """

  @handler_id :elixirgateway_json

  def attach(path, level \\ :info) do
    File.mkdir_p!(Path.dirname(path))
    :logger.remove_handler(@handler_id)

    :logger.add_handler(@handler_id, :logger_std_h, %{
      level: level,
      config: %{
        type: {:file, String.to_charlist(path)},
        max_no_bytes: 10_000_000,
        max_no_files: 3
      },
      formatter: {__MODULE__, %{}}
    })
  end

  def detach, do: :logger.remove_handler(@handler_id)

  # --- OTP :logger formatter callback ---

  def format(%{level: level, msg: msg, meta: meta}, _config) do
    entry =
      %{
        timestamp: format_timestamp(meta[:time]),
        level: level,
        message: format_message(msg),
        node: node()
      }
      |> Map.merge(extract_metadata(meta))

    case Jason.encode(entry) do
      {:ok, json} -> [json, "\n"]
      {:error, _} -> [Jason.encode!(%{entry | message: inspect(msg)}), "\n"]
    end
  rescue
    _ -> ""
  end

  # --- Private ---

  defp format_timestamp(time) when is_integer(time) do
    case DateTime.from_unix(time, :microsecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp format_timestamp(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp format_message({:string, msg}), do: IO.iodata_to_binary(msg)
  defp format_message({:report, report}) when is_map(report), do: sanitize(report)
  defp format_message({:report, report}), do: inspect(report)

  defp format_message({format, args}) when is_list(args) do
    :io_lib.format(format, args) |> IO.iodata_to_binary()
  rescue
    _ -> inspect({format, args})
  end

  defp format_message(other), do: inspect(other)

  defp extract_metadata(meta) do
    meta
    |> Map.take([:request_id, :module, :function, :line, :pid, :domain])
    |> Map.new(fn
      {:pid, pid} -> {:pid, inspect(pid)}
      {:domain, domain} -> {:domain, Enum.map(domain, &to_string/1)}
      {:module, mod} -> {:module, inspect(mod)}
      {:function, f} -> {:function, to_string(f)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_map(v), do: sanitize(v)
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)
  defp sanitize_value(v) when is_binary(v), do: v
  defp sanitize_value(v), do: inspect(v)
end
