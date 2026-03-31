defmodule ElixirGateway.JsonLogHandler do
  @moduledoc """
  OTP :logger handler writing JSON log lines to a file for Grafana Alloy ingestion.
  Runs alongside the :console handler — stdout format is unchanged.

  Enable by setting JSON_LOG_PATH to a path in the shared Docker volume, e.g.:
      JSON_LOG_PATH=/app/logs/app.json.log
  """

  @handler_id :elixirgateway_json

  def attach(path, level \\ :info) do
    File.mkdir_p!(Path.dirname(path))
    # Remove stale handler if present (e.g. after a hot reload)
    :logger.remove_handler(@handler_id)

    :logger.add_handler(@handler_id, __MODULE__, %{
      config: %{path: path},
      level: level,
      filter_default: :log
    })
  end

  def detach, do: :logger.remove_handler(@handler_id)

  # --- OTP :logger handler callbacks ---

  def adding_handler(%{config: %{path: path}} = config) do
    case File.open(path, [:append, :utf8]) do
      {:ok, device} -> {:ok, put_in(config, [:config, :device], device)}
      {:error, reason} -> {:error, reason}
    end
  end

  def removing_handler(%{config: %{device: device}}), do: File.close(device)
  def removing_handler(_config), do: :ok

  def changing_config(_action, _old, new_config), do: {:ok, new_config}

  def log(%{level: level, msg: msg, meta: meta}, %{config: %{device: device}}) do
    entry = %{
      timestamp: format_timestamp(meta[:time]),
      level: level,
      message: format_message(msg),
      node: node(),
      metadata: extract_metadata(meta)
    }

    case Jason.encode(entry) do
      {:ok, json} -> IO.puts(device, json)
      {:error, _} -> IO.puts(device, Jason.encode!(%{entry | message: inspect(msg), metadata: %{}}))
    end
  rescue
    _ -> :ok
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
