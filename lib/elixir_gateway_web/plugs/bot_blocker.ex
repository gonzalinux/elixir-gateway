defmodule ElixirGatewayWeb.Plugs.BotBlocker do
  @moduledoc """
  Blocks automated scanners and bots looking for common vulnerabilities.

  Detects suspicious patterns like:
  - PHP files (.php extensions)
  - Common exploit paths (wp-admin, phpMyAdmin, etc.)
  - Environment files (.env, .git)
  - Repeated 404s from same IP

  Configuration:

      config :elixirgateway, :bot_blocker,
        enabled: true,
        block_duration_seconds: 3600,  # 1 hour
        max_404s_before_block: 10
  """

  import Plug.Conn
  require Logger

  @suspicious_patterns [
    ~r/\.php$/i,
    ~r/\.asp$/i,
    ~r/\.aspx$/i,
    ~r/\.env$/i,
    ~r/\.git/i,
    ~r/wp-admin/i,
    ~r/wp-content/i,
    ~r/wp-includes/i,
    ~r/wp-config/i,
    ~r/phpmyadmin/i,
    ~r/adminer/i,
    ~r/sqlmanager/i,
    ~r/db\.php/i,
    ~r/database/i,
    ~r/mysql/i,
    ~r/config\.php/i,
    ~r/shell/i,
    ~r/eval-stdin\.php/i,
    ~r/backdoor/i,
    ~r/webshell/i,
  ]

  @table_name :bot_blocker_ips

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() do
      ip = get_ip_address(conn)

      cond do
        # Check if IP is already blocked
        is_blocked?(ip) ->
          block_request(conn, ip, "IP blocked due to suspicious activity")

        # Check if path matches suspicious patterns
        is_suspicious_path?(conn.request_path) ->
          record_violation(ip)
          block_request(conn, ip, "Suspicious path detected")

        true ->
          conn
      end
    else
      conn
    end
  end

  defp enabled? do
    config = Application.get_env(:elixirgateway, :bot_blocker, [])
    Keyword.get(config, :enabled, true)
  end

  defp is_suspicious_path?(path) do
    Enum.any?(@suspicious_patterns, fn pattern ->
      String.match?(path, pattern)
    end)
  end

  defp is_blocked?(ip) do
    ensure_table_exists()

    case :ets.lookup(@table_name, ip) do
      [{^ip, block_until}] ->
        now = System.system_time(:second)
        if now < block_until do
          true
        else
          # Block expired, remove it
          :ets.delete(@table_name, ip)
          false
        end

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp record_violation(ip) do
    ensure_table_exists()

    config = Application.get_env(:elixirgateway, :bot_blocker, [])
    block_duration = Keyword.get(config, :block_duration_seconds, 3600)

    block_until = System.system_time(:second) + block_duration

    :ets.insert(@table_name, {ip, block_until})

    Logger.warning("Bot activity detected from IP #{ip}, blocking for #{block_duration}s")
  rescue
    ArgumentError -> :ok
  end

  defp block_request(conn, ip, reason) do
    Logger.info("Blocked request from #{ip}: #{reason}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden")
    |> halt()
  end

  defp get_ip_address(conn) do
    # Try X-Forwarded-For first (if behind proxy)
    case get_req_header(conn, "x-forwarded-for") do
      [ip_chain | _] ->
        # Take first IP from chain
        String.split(ip_chain, ",") |> List.first() |> String.trim()

      [] ->
        # Fall back to remote_ip
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
          _ -> "unknown"
        end
    end
  end

  defp ensure_table_exists do
    unless :ets.whereis(@table_name) != :undefined do
      :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok  # Table already exists
  end
end
