defmodule ElixirGateway.Cluster.Jobs.CertRenewalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias ElixirGateway.Cluster.Jobs.CertRenewal

  setup do
    original_cert_store = Application.get_env(:elixirgateway, :cert_store)
    original_http_domains = Application.get_env(:elixirgateway, :letsencrypt_domains)
    original_dns_domains = Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains)
    original_is_primary = System.get_env("IS_PRIMARY")
    original_log_level = Logger.level()

    temp_dir = Path.join(System.tmp_dir!(), "cert_renewal_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(temp_dir)

    Application.put_env(:elixirgateway, :cert_store,
      certbot_config_dir: temp_dir,
      dev_cert_dir: "priv/certs"
    )

    Logger.configure(level: :debug)

    on_exit(fn ->
      restore_env(:cert_store, original_cert_store)
      restore_env(:letsencrypt_domains, original_http_domains)
      restore_env(:letsencrypt_wildcard_domains, original_dns_domains)

      case original_is_primary do
        nil -> System.delete_env("IS_PRIMARY")
        val -> System.put_env("IS_PRIMARY", val)
      end

      Logger.configure(level: original_log_level)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  describe "needs_renewal?/1" do
    test "returns true when no cert file exists on disk" do
      assert CertRenewal.needs_renewal?("no-cert.example") == true
    end

    test "returns true when cert expires within 30 days", %{temp_dir: temp_dir} do
      domain = "expiring-soon.example"
      live_dir = Path.join([temp_dir, "live", domain])
      File.mkdir_p!(live_dir)
      generate_cert(Path.join(live_dir, "fullchain.pem"), domain, 15)

      assert CertRenewal.needs_renewal?(domain) == true
    end

    test "returns false when cert expires in more than 30 days", %{temp_dir: temp_dir} do
      domain = "valid-cert.example"
      live_dir = Path.join([temp_dir, "live", domain])
      File.mkdir_p!(live_dir)
      generate_cert(Path.join(live_dir, "fullchain.pem"), domain, 90)

      assert CertRenewal.needs_renewal?(domain) == false
    end

    test "returns true at the 30-day boundary", %{temp_dir: temp_dir} do
      domain = "boundary-cert.example"
      live_dir = Path.join([temp_dir, "live", domain])
      File.mkdir_p!(live_dir)
      generate_cert(Path.join(live_dir, "fullchain.pem"), domain, 29)

      assert CertRenewal.needs_renewal?(domain) == true
    end
  end

  describe "run/0 — secondary node" do
    test "skips renewal and logs debug on secondary node" do
      System.put_env("IS_PRIMARY", "false")
      Application.put_env(:elixirgateway, :letsencrypt_domains, ["example.com"])

      log = capture_log(fn -> CertRenewal.run() end)

      assert log =~ "secondary node, skipping"
    end
  end

  describe "run/0 — primary node" do
    test "logs that all certs are up to date when no domains are configured" do
      System.put_env("IS_PRIMARY", "true")
      Application.put_env(:elixirgateway, :letsencrypt_domains, [])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      log = capture_log(fn -> CertRenewal.run() end)

      assert log =~ "all 0 cert(s) are up to date"
    end

    test "queues renewal for domains with no cert on disk", %{temp_dir: _temp_dir} do
      System.put_env("IS_PRIMARY", "true")
      Application.put_env(:elixirgateway, :letsencrypt_domains, ["no-cert-domain.example"])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      log = capture_log(fn -> CertRenewal.run() end)

      assert log =~ "queuing renewal"
      assert log =~ "no-cert-domain.example"
    end

    test "skips domains with valid certs", %{temp_dir: temp_dir} do
      System.put_env("IS_PRIMARY", "true")
      domain = "valid-primary.example"
      live_dir = Path.join([temp_dir, "live", domain])
      File.mkdir_p!(live_dir)
      generate_cert(Path.join(live_dir, "fullchain.pem"), domain, 90)

      Application.put_env(:elixirgateway, :letsencrypt_domains, [domain])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      log = capture_log(fn -> CertRenewal.run() end)

      assert log =~ "all 1 cert(s) are up to date"
      refute log =~ "queuing renewal"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:elixirgateway, key)
  defp restore_env(key, val), do: Application.put_env(:elixirgateway, key, val)

  defp generate_cert(cert_path, cn, days) do
    key_path = cert_path <> ".key"

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "ec",
          "-pkeyopt",
          "ec_paramgen_curve:P-256",
          "-nodes",
          "-keyout",
          key_path,
          "-out",
          cert_path,
          "-days",
          Integer.to_string(days),
          "-subj",
          "/CN=#{cn}"
        ],
        stderr_to_stdout: true
      )
  end
end
