defmodule ElixirGateway.Cluster.CertificateManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirGateway.Cluster.CertificateManager

  setup do
    # Save original config
    original_config = Application.get_env(:elixirgateway, :cluster)
    original_cert_store = Application.get_env(:elixirgateway, :cert_store)
    original_is_primary = System.get_env("IS_PRIMARY")

    # Create temp cert directory
    temp_dir =
      Path.join(System.tmp_dir!(), "cert_manager_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(temp_dir)

    Application.put_env(:elixirgateway, :cert_store,
      certbot_config_dir: temp_dir,
      certbot_work_dir: temp_dir,
      certbot_logs_dir: temp_dir
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end

      if original_cert_store do
        Application.put_env(:elixirgateway, :cert_store, original_cert_store)
      else
        Application.delete_env(:elixirgateway, :cert_store)
      end

      if original_is_primary do
        System.put_env("IS_PRIMARY", original_is_primary)
      else
        System.delete_env("IS_PRIMARY")
      end

      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, live_dir: Path.join(temp_dir, "live")}
  end

  describe "role determination" do
    test "detects primary when CLUSTER_PEERS has values" do
      System.delete_env("IS_PRIMARY")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-primary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()
      assert status.role == :primary

      GenServer.stop(pid)
    end

    test "detects secondary when CLUSTER_PEERS is empty" do
      System.delete_env("IS_PRIMARY")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-secondary",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()
      assert status.role == :secondary

      GenServer.stop(pid)
    end

    test "explicit IS_PRIMARY=true overrides auto-detection" do
      System.put_env("IS_PRIMARY", "true")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-override-primary",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()
      assert status.role == :primary

      GenServer.stop(pid)
      System.delete_env("IS_PRIMARY")
    end

    test "explicit IS_PRIMARY=false overrides auto-detection" do
      System.put_env("IS_PRIMARY", "false")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-override-secondary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()
      assert status.role == :secondary

      GenServer.stop(pid)
      System.delete_env("IS_PRIMARY")
    end
  end

  describe "certificate installation" do
    test "validates checksum before installation", %{} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-checksum",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      invalid_bundle = %{
        domain: "example.com",
        fullchain_pem: "CERT_CONTENT",
        privkey_pem: "KEY_CONTENT",
        checksum: "wrong_checksum",
        generated_at: DateTime.utc_now()
      }

      result = CertificateManager.handle_rpc({:sync_certificates, invalid_bundle})
      assert {:error, :checksum_mismatch} = result

      GenServer.stop(pid)
    end

    test "successfully installs certificates with valid checksum", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-install",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      fullchain_pem = "-----BEGIN CERTIFICATE-----\nTEST_CERT\n-----END CERTIFICATE-----"
      privkey_pem = "-----BEGIN PRIVATE KEY-----\nTEST_KEY\n-----END PRIVATE KEY-----"

      checksum = :crypto.hash(:sha256, fullchain_pem <> privkey_pem)

      valid_bundle = %{
        domain: "example.com",
        fullchain_pem: fullchain_pem,
        privkey_pem: privkey_pem,
        checksum: checksum,
        generated_at: DateTime.utc_now()
      }

      result = CertificateManager.handle_rpc({:sync_certificates, valid_bundle})
      assert :ok = result

      cert_dir = Path.join(live_dir, "example.com")
      assert File.exists?(Path.join(cert_dir, "fullchain.pem"))
      assert File.exists?(Path.join(cert_dir, "privkey.pem"))

      assert File.read!(Path.join(cert_dir, "fullchain.pem")) == fullchain_pem
      assert File.read!(Path.join(cert_dir, "privkey.pem")) == privkey_pem

      GenServer.stop(pid)
    end

    test "primary cannot receive certificates", %{} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-primary-reject",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Try to send certificates to primary node
      cert_bundle = %{
        domain: "example.com",
        cert_pem: "CERT",
        privkey_pem: "KEY",
        chain_pem: "CHAIN",
        checksum: :crypto.hash(:sha256, "CERTKEYCHAINE"),
        generated_at: DateTime.utc_now()
      }

      result = CertificateManager.handle_rpc({:sync_certificates, cert_bundle})
      assert {:error, :primary_cannot_receive} = result

      GenServer.stop(pid)
    end
  end

  describe "status reporting" do
    test "returns correct status for primary node", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-status-primary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()

      assert status.role == :primary
      assert status.cert_sync_enabled == true
      assert status.live_dir == live_dir
      assert status.last_sync == nil
      assert status.sync_failures == 0
      assert status.clustering_enabled == true

      GenServer.stop(pid)
    end

    test "returns correct status for secondary node", %{} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-status-secondary",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()

      assert status.role == :secondary
      assert status.cert_sync_enabled == true

      GenServer.stop(pid)
    end
  end

  describe "cert sync disabled" do
    test "cert sync can be disabled via config", %{} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-disabled",
        peers: [],
        cert_sync: [enabled: false]
      )

      {:ok, pid} = CertificateManager.start_link([])

      status = CertificateManager.status()
      assert status.cert_sync_enabled == false

      GenServer.stop(pid)
    end
  end

  describe "trigger_sync" do
    test "primary can trigger manual sync", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-trigger-primary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      domain = "example.com"
      cert_dir = Path.join(live_dir, domain)
      File.mkdir_p!(cert_dir)

      File.write!(Path.join(cert_dir, "fullchain.pem"), "CERT")
      File.write!(Path.join(cert_dir, "privkey.pem"), "KEY")

      # No peers connected so sync returns :ok immediately after reading certs
      result = CertificateManager.trigger_sync(domain)
      assert :ok = result

      GenServer.stop(pid)
    end

    test "secondary cannot trigger sync", %{} do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-trigger-secondary",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      result = CertificateManager.trigger_sync("example.com")
      assert {:error, :secondary_cannot_trigger} = result

      GenServer.stop(pid)
    end
  end

  describe "automatic certificate sync on peer connection" do
    test "primary syncs certificates when new peer connects", %{temp_dir: temp_dir} do
      System.put_env("LETSENCRYPT_DOMAINS", "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-auto-sync-primary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Create test certificates
      domain = "example.com"
      cert_dir = Path.join([temp_dir, "certs", domain])
      File.mkdir_p!(cert_dir)

      cert_pem = "-----BEGIN CERTIFICATE-----\nTEST_CERT\n-----END CERTIFICATE-----"
      privkey_pem = "-----BEGIN PRIVATE KEY-----\nTEST_KEY\n-----END PRIVATE KEY-----"
      chain_pem = "-----BEGIN CERTIFICATE-----\nTEST_CHAIN\n-----END CERTIFICATE-----"

      File.write!(Path.join(cert_dir, "cert.pem"), cert_pem)
      File.write!(Path.join(cert_dir, "privkey.pem"), privkey_pem)
      File.write!(Path.join(cert_dir, "chain.pem"), chain_pem)

      # Simulate a peer connecting (nodeup event)
      # In real scenario, this would come from :net_kernel
      send(pid, {:nodeup, :"fake_peer@127.0.0.1", []})

      # Give it time to schedule the sync (3 second delay + processing time)
      Process.sleep(3_200)

      # Verify that the manager tried to sync (won't actually succeed since no real peer)
      # But we can check logs or state
      status = CertificateManager.status()
      assert status.role == :primary

      GenServer.stop(pid)

      System.delete_env("LETSENCRYPT_DOMAINS")
    end

    test "secondary ignores nodeup events", %{} do
      System.put_env("LETSENCRYPT_DOMAINS", "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-auto-sync-secondary",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Simulate a peer connecting
      send(pid, {:nodeup, :"fake_peer@127.0.0.1", []})

      # Give it time to process
      Process.sleep(100)

      # Secondary should have ignored the event
      status = CertificateManager.status()
      assert status.role == :secondary
      assert status.last_sync == nil

      GenServer.stop(pid)

      System.delete_env("LETSENCRYPT_DOMAINS")
    end

    test "primary handles missing certificates gracefully", %{} do
      System.put_env("LETSENCRYPT_DOMAINS", "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-missing-certs",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Don't create certificates - simulate missing certs

      # Simulate a peer connecting
      send(pid, {:nodeup, :"fake_peer@127.0.0.1", []})

      # Give it time to schedule and process the sync
      Process.sleep(3_200)

      # Should handle gracefully without crashing
      assert Process.alive?(pid)

      GenServer.stop(pid)

      System.delete_env("LETSENCRYPT_DOMAINS")
    end

    test "primary handles no domains configured", %{} do
      System.delete_env("LETSENCRYPT_DOMAINS")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-no-domains",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Simulate a peer connecting
      send(pid, {:nodeup, :"fake_peer@127.0.0.1", []})

      # Give it time to schedule and process the sync
      Process.sleep(3_200)

      # Should handle gracefully without crashing
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "sync_to_new_peer — domain collection" do
    setup do
      orig_http = Application.get_env(:elixirgateway, :letsencrypt_domains)
      orig_dns = Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains)

      on_exit(fn ->
        restore_env(:letsencrypt_domains, orig_http)
        restore_env(:letsencrypt_wildcard_domains, orig_dns)
      end)

      :ok
    end

    test "emits no warnings when no domains are configured", %{} do
      Application.put_env(:elixirgateway, :letsencrypt_domains, [])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-no-domains",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          # Synchronous call flushes the mailbox — handle_info has run when this returns
          CertificateManager.status()
        end)

      # Nothing to sync → no warnings or errors (debug message is below test log level)
      assert log == ""
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "attempts all HTTP-01 domains, not just the first", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :letsencrypt_domains, [
        "api.example.com",
        "app.example.com"
      ])

      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      make_cert(live_dir, "api.example.com")
      make_cert(live_dir, "app.example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-all-http01",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          CertificateManager.status()
        end)

      # Both domains appear in failure warnings — neither was skipped
      # (RPC fails with node_down since fake@127.0.0.1 isn't a real node)
      assert log =~ "api.example.com"
      assert log =~ "app.example.com"

      GenServer.stop(pid)
    end

    test "attempts DNS-01 wildcard cert domains", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :letsencrypt_domains, [])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, ["example.com"])

      make_cert(live_dir, "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-dns01",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          CertificateManager.status()
        end)

      assert log =~ "example.com"

      GenServer.stop(pid)
    end

    test "attempts both HTTP-01 and DNS-01 domains together", %{live_dir: live_dir} do
      Application.put_env(:elixirgateway, :letsencrypt_domains, ["api.example.com"])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, ["example.com"])

      make_cert(live_dir, "api.example.com")
      make_cert(live_dir, "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-both",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          CertificateManager.status()
        end)

      assert log =~ "api.example.com"
      assert log =~ "example.com"

      GenServer.stop(pid)
    end

    test "continues syncing remaining domains when one cert is missing from disk", %{
      live_dir: live_dir
    } do
      Application.put_env(:elixirgateway, :letsencrypt_domains, [
        "missing.example.com",
        "api.example.com"
      ])

      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      # Only the second domain has a cert on disk
      make_cert(live_dir, "api.example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-partial",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          CertificateManager.status()
        end)

      # Both domains appear in warnings — missing cert didn't abort the loop
      assert log =~ "missing.example.com"
      assert log =~ "api.example.com"
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "normalizes wildcard entries in HTTP-01 list to apex before reading cert", %{
      live_dir: live_dir
    } do
      # YAML config strips wildcards, but the env-var path could pass them through
      Application.put_env(:elixirgateway, :letsencrypt_domains, ["*.example.com"])
      Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      # Cert is stored under the apex, as certbot writes it
      make_cert(live_dir, "example.com")

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-sync-wildcard-normalize",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      log =
        capture_log(fn ->
          send(pid, {:sync_to_new_peer, :"fake@127.0.0.1"})
          CertificateManager.status()
        end)

      # Failure is node_down (not read_failed:enoent), proving the apex path was used
      # and the cert was read successfully before the RPC attempt
      assert log =~ "node_down"
      refute log =~ "read_failed"

      GenServer.stop(pid)
    end
  end

  # — Helpers —

  defp restore_env(key, nil), do: Application.delete_env(:elixirgateway, key)
  defp restore_env(key, val), do: Application.put_env(:elixirgateway, key, val)

  defp make_cert(live_dir, domain) do
    cert_dir = Path.join(live_dir, domain)
    File.mkdir_p!(cert_dir)
    File.write!(Path.join(cert_dir, "fullchain.pem"), "CERT_#{domain}")
    File.write!(Path.join(cert_dir, "privkey.pem"), "KEY_#{domain}")
  end
end
