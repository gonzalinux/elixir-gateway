defmodule ElixirGateway.CertbotRunner do
  @moduledoc """
  Serial queue for certbot invocations.

  certbot uses a lock file, so only one invocation can run at a time. This
  GenServer queues requests and processes them one at a time via a Task,
  keeping the GenServer responsive while certbot runs for 30-60 seconds.

  On success, CertStore is reloaded so the new cert is immediately available
  for TLS handshakes without any restart.
  """

  use GenServer
  require Logger

  defstruct queue: :queue.new(), task: nil, current_item: nil

  # — Public API —

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queues an HTTP-01 cert issuance/renewal for a single domain.
  Certbot skips the ACME round-trip if the cert is still valid for >30 days.
  """
  def ensure_cert(domain) do
    GenServer.cast(__MODULE__, {:ensure_cert, domain})
  end

  @doc """
  Queues a DNS-01 cert issuance for the wildcard certs.
  Requires a Cloudflare credentials file at the configured path.
  """
  def ensure_wildcard_cert(apex_domain) do
    GenServer.cast(__MODULE__, {:ensure_wildcard, apex_domain})
  end

  # — GenServer callbacks —

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:ensure_cert, domain}, state) do
    {:noreply, enqueue(state, {:http01, domain})}
  end

  @impl true
  def handle_cast({:ensure_wildcard, apex_domain}, state) do
    {:noreply, enqueue(state, {:dns01, apex_domain})}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        ElixirGateway.CertStore.reload()
        notify_cert_manager(state.current_item)

      {:error, reason} ->
        Logger.error("CertbotRunner: certbot failed — #{reason}")
    end

    {:noreply, dispatch(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("CertbotRunner: certbot task crashed — #{inspect(reason)}")
    {:noreply, dispatch(%{state | task: nil})}
  end

  def handle_info(_, state), do: {:noreply, state}

  # — Private —

  defp enqueue(state, item) do
    dispatch(%{state | queue: :queue.in(item, state.queue)})
  end

  defp dispatch(%{task: task} = state) when not is_nil(task), do: state

  defp dispatch(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, item}, rest} ->
        task =
          Task.Supervisor.async_nolink(ElixirGateway.CertbotRunner.TaskSupervisor, fn ->
            run(item)
          end)

        %{state | queue: rest, task: task, current_item: item}
    end
  end

  defp run({:http01, domain}) do
    Logger.info("CertbotRunner: issuing/renewing HTTP-01 cert for #{domain}")
    args = http01_args(domain)
    certbot(args)
  end

  defp run({:dns01, apex_domain}) do
    Logger.info("CertbotRunner: issuing/renewing DNS-01 wildcard cert for #{apex_domain}")
    args = dns01_args(apex_domain)
    certbot(args)
  end

  defp notify_cert_manager({_, domain}) do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])

    if Keyword.get(cluster_config, :enabled, false) do
      ElixirGateway.Cluster.CertificateManager.on_certificates_generated(domain)
    end
  end

  defp certbot(args) do
    base_args = [
      "--config-dir",
      config(:certbot_config_dir),
      "--work-dir",
      config(:certbot_work_dir),
      "--logs-dir",
      config(:certbot_logs_dir),
      "--non-interactive",
      "--agree-tos",
      "--email",
      letsencrypt_email()
    ]

    case System.cmd("certbot", ["certonly"] ++ args ++ base_args, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("CertbotRunner: certbot succeeded\n#{output}")
        :ok

      {output, code} ->
        {:error, "exit #{code}\n#{output}"}
    end
  end

  defp http01_args(domain) do
    [
      "--webroot",
      "--webroot-path",
      config(:acme_webroot),
      "--cert-name",
      domain,
      "-d",
      domain
    ]
  end

  defp dns01_args(apex_domain) do
    [
      "--dns-cloudflare",
      "--dns-cloudflare-credentials",
      config(:cloudflare_credentials),
      "--cert-name",
      apex_domain,
      "-d",
      apex_domain,
      "-d",
      "*.#{apex_domain}"
    ]
  end

  defp config(key) do
    Application.get_env(:elixirgateway, :cert_store, [])
    |> Keyword.get(key)
  end

  defp letsencrypt_email do
    System.get_env("LETSENCRYPT_EMAIL") ||
      raise "LETSENCRYPT_EMAIL env var is required for certbot"
  end
end
