defmodule ElixirGatewayWeb.Endpoint do
  # Role-aware endpoint: Primary nodes run ACME challenges, secondary nodes use manual cert mode
  # Secondary nodes (IS_PRIMARY=false) receive certificates via cluster sync from primary
  # This prevents multiple nodes from attempting Let's Encrypt challenges simultaneously
  use SiteEncrypt.Phoenix.Endpoint, otp_app: :elixirgateway

  require Logger

  @impl SiteEncrypt
  def certification do
    # Check if this is a secondary node at runtime
    is_secondary = System.get_env("IS_PRIMARY") == "false"

    if is_secondary do
      # Secondary node: Configure like dev/test environment with internal ACME server
      # This prevents real ACME challenges while allowing SiteEncrypt to use existing certs
      # Certificates will be provided via cluster sync from primary node
      Logger.info(
        "Endpoint running as SECONDARY node - using internal ACME mode, no external challenges"
      )

      acme_port = System.get_env("ACME_SERVER_PORT", "4005") |> String.to_integer()

      SiteEncrypt.configure(
        # Use native client but with internal ACME server (won't contact Let's Encrypt)
        client: :native,
        domains: ElixirGateway.SiteEncrypt.get_domains(),
        emails: [ElixirGateway.SiteEncrypt.get_email()],
        db_folder: System.get_env("SITE_ENCRYPT_DB", Path.join("priv", "certs")),
        # Internal ACME server (like dev mode) - won't be running, so no challenges attempted
        directory_url: {:internal, port: acme_port}
      )
    else
      # Primary node: Normal SiteEncrypt operation
      Logger.info("Endpoint running as PRIMARY node - SiteEncrypt enabled")

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
  end

  @impl SiteEncrypt
  def handle_new_cert do
    # Only run on primary nodes
    is_secondary = System.get_env("IS_PRIMARY") == "false"

    if is_secondary do
      # Secondary nodes should never receive this callback, but if they do, ignore it
      Logger.warning("Secondary node received handle_new_cert callback - ignoring")
      :ok
    else
      # Primary node: process certificate generation
      cert_config = certification()

      if cert_config.domains != [] do
        domain = hd(cert_config.domains)

        # Notify certificate manager (no-op if clustering disabled)
        if cluster_cert_sync_enabled?() do
          ElixirGateway.Cluster.CertificateManager.on_certificates_generated(domain)
        end
      end

      :ok
    end
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
