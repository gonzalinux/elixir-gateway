defmodule ElixirGatewayWeb.Endpoint do
  use SiteEncrypt.Phoenix.Endpoint, otp_app: :elixirgateway

  @impl SiteEncrypt
  def certification do
    SiteEncrypt.configure(
      # Note that native client is very immature. If you want a more stable behaviour, you can
      # provide `:certbot` instead. Note that in this case certbot needs to be installed on the
      # host machine.
      client: :native,
      domains: ElixirGateway.SiteEncrypt.get_domains(),
      emails: [ElixirGateway.SiteEncrypt.get_email()],

      # By default the certs will be stored in tmp/site_encrypt_db, which is convenient for
      # local development. Make sure that tmp folder is gitignored.
      #
      # Set OS env var SITE_ENCRYPT_DB on staging/production hosts to some absolute path
      # outside of the deployment folder. Otherwise, the deploy may delete the db_folder,
      # which will effectively remove the generated key and certificate files.
      db_folder: System.get_env("SITE_ENCRYPT_DB", Path.join("priv", "certs")),

      # set OS env var CERT_MODE to "staging" or "production" on staging/production hosts
      directory_url:
        case Application.get_env(:elixirgateway, :env) do
          :dev ->
            acme_port = System.get_env("ACME_SERVER_PORT", "4005") |> String.to_integer()
            {:internal, port: acme_port}

          :test ->
            acme_port = System.get_env("ACME_SERVER_PORT", "4005") |> String.to_integer()
            {:internal, port: acme_port}

          :stage ->
            "https://acme-staging-v02.api.letsencrypt.org/directory"

          :prod ->
            "https://acme-v02.api.letsencrypt.org/directory"
        end
    )
  end

  @impl SiteEncrypt
  def handle_new_cert do
    # Get the first domain from the certification config
    cert_config = certification()
    domain = hd(cert_config.domains)

    # Notify certificate manager (no-op if clustering disabled)
    if cluster_cert_sync_enabled?() do
      ElixirGateway.Cluster.CertificateManager.on_certificates_generated(domain)
    end

    :ok
  end

  defp cluster_cert_sync_enabled? do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    clustering_enabled = Keyword.get(cluster_config, :enabled, false)

    if clustering_enabled do
      cert_sync_config = Keyword.get(cluster_config, :cert_sync, [])
      Keyword.get(cert_sync_config, :enabled, true)
    else
      false
    end
  end

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_elixirgateway_key",
    signing_salt: "M6TOtxbf",
    same_site: "Lax"
  ]

  # socket "/live", Phoenix.LiveView.Socket,
  # websocket: [connect_info: [session: @session_options]],
  # longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.

  if Code.ensure_loaded?(Tidewave) do
    plug(Tidewave)
  end

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["application/x-www-form-urlencoded", "multipart/form-data", "application/json"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(ElixirGatewayWeb.Router)
end
