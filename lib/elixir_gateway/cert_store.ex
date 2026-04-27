defmodule ElixirGateway.CertStore do
  @moduledoc """
  ETS-backed certificate store for SNI-based TLS.

  Scans the certbot live directory at startup and on reload, reads the SANs
  from each certificate, and indexes them so the SNI callback can do a plain
  ETS lookup on every TLS handshake.

  For wildcard certs (e.g. *.writeinone.com stored under writeinone.com/),
  a second lookup strips the first DNS label before checking ETS — no regex
  or glob matching is needed because the SAN is stored as-is.

  Falls back to priv/certs/{cert,key}.pem when no cert matches (useful in
  dev/test where certbot is not running).
  """

  use GenServer
  require Logger

  @table :cert_store

  # — Public API —

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  SNI callback for Bandit transport_options.
  Receives the server_name as a charlist, returns ssl options or :undefined.
  """
  def sni_fun(server_name) do
    domain = List.to_string(server_name)
    lookup(domain) || wildcard_lookup(domain) || dev_fallback() || :undefined
  end

  @doc "Rescans cert directories and rebuilds ETS. Called after certbot runs."
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @doc """
  Returns the number of days until the cert for the given domain expires,
  or :no_cert if no cert file exists on disk.
  Reads directly from disk so it reflects the current file, not the ETS snapshot.
  """
  def days_until_expiry(domain) do
    fullchain = Path.join([certbot_live_dir(), domain, "fullchain.pem"])

    with {:ok, pem} <- File.read(fullchain),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem),
         {:OTPCertificate, {:OTPTBSCertificate, _, _, _, _, validity, _, _, _, _, _}, _, _} <-
           :public_key.pkix_decode_cert(der, :otp),
         {:Validity, _, not_after} <- validity,
         {:ok, expiry, _offset} <- parse_asn1_time(not_after) do
      DateTime.diff(expiry, DateTime.utc_now(), :day)
    else
      _ -> :no_cert
    end
  end

  # — GenServer callbacks —

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    populate()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:reload, state) do
    :ets.delete_all_objects(@table)
    populate()
    {:noreply, state}
  end

  # — Private —

  defp populate do
    live_dir = certbot_live_dir()

    if File.dir?(live_dir) do
      live_dir
      |> File.ls!()
      |> Enum.each(&load_cert_dir(live_dir, &1))
    else
      Logger.debug("CertStore: #{live_dir} not found, no certbot certs loaded")
    end

    Logger.info("CertStore: #{:ets.info(@table, :size)} SNI entries loaded")
  end

  defp load_cert_dir(live_dir, domain) do
    cert_dir = Path.join(live_dir, domain)
    fullchain = Path.join(cert_dir, "fullchain.pem")
    privkey = Path.join(cert_dir, "privkey.pem")

    with true <- File.exists?(fullchain),
         true <- File.exists?(privkey),
         {:ok, pem} <- File.read(fullchain),
         [_ | _] = sans <- cert_sans(pem) do
      ssl_opts = [certfile: fullchain, keyfile: privkey]
      Enum.each(sans, fn san -> :ets.insert(@table, {san, ssl_opts}) end)
      Logger.debug("CertStore: loaded #{domain} (#{length(sans)} SANs)")
    else
      _ -> Logger.warning("CertStore: skipped #{domain} — missing or unreadable cert files")
    end
  end

  defp lookup(domain) do
    case :ets.lookup(@table, domain) do
      [{_, ssl_opts}] -> ssl_opts
      [] -> nil
    end
  end

  defp wildcard_lookup(domain) do
    case String.split(domain, ".", parts: 2) do
      [_, parent] -> lookup("*." <> parent)
      _ -> nil
    end
  end

  defp dev_fallback do
    dir = cert_store_config(:dev_cert_dir)
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    if File.exists?(cert) and File.exists?(key) do
      [certfile: cert, keyfile: key]
    end
  end

  defp cert_sans(pem_binary) do
    with [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem_binary),
         {:OTPCertificate, {:OTPTBSCertificate, _, _, _, _, _, _, _, _, _, extensions}, _, _} <-
           :public_key.pkix_decode_cert(der, :otp),
         exts when is_list(exts) <- extensions do
      for {:Extension, {2, 5, 29, 17}, _, san_list} <- exts,
          {:dNSName, name} <- san_list do
        List.to_string(name)
      end
    else
      _ -> []
    end
  end

  # ASN.1 UTCTime:     YYMMDDHHMMSSZ  (2-digit year; <50 = 20xx, >=50 = 19xx)
  # ASN.1 GeneralTime: YYYYMMDDHHMMSSZ
  defp parse_asn1_time({:utcTime, time}) do
    <<y2::binary-2, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, _::binary>> =
      List.to_string(time)

    year = if String.to_integer(y2) >= 50, do: "19#{y2}", else: "20#{y2}"
    DateTime.from_iso8601("#{year}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z")
  end

  defp parse_asn1_time({:generalTime, time}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, _::binary>> =
      List.to_string(time)

    DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z")
  end

  defp parse_asn1_time(_), do: :error

  defp cert_store_config(key) do
    Application.get_env(:elixirgateway, :cert_store, [])
    |> Keyword.get(key)
  end

  defp certbot_live_dir do
    cert_store_config(:certbot_config_dir)
    |> Path.join("live")
  end
end
