defmodule ElixirGateway.Cluster.CertificateManagerTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.Cluster.CertificateManager

  setup do
    # Save original config
    original_config = Application.get_env(:elixirgateway, :cluster)
    original_is_primary = System.get_env("IS_PRIMARY")

    # Create temp cert directory
    temp_dir =
      Path.join(System.tmp_dir!(), "cert_manager_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end

      if original_is_primary do
        System.put_env("IS_PRIMARY", original_is_primary)
      else
        System.delete_env("IS_PRIMARY")
      end

      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
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
    test "validates checksum before installation", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-checksum",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Create invalid cert bundle with wrong checksum
      invalid_bundle = %{
        domain: "example.com",
        cert_pem: "CERT_CONTENT",
        privkey_pem: "KEY_CONTENT",
        chain_pem: "CHAIN_CONTENT",
        checksum: "wrong_checksum",
        generated_at: DateTime.utc_now()
      }

      result = CertificateManager.receive_certificates(invalid_bundle)
      assert {:error, :checksum_mismatch} = result

      GenServer.stop(pid)
      System.delete_env("SITE_ENCRYPT_DB")
    end

    test "successfully installs certificates with valid checksum", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-install",
        peers: []
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Create valid cert bundle
      cert_pem = "-----BEGIN CERTIFICATE-----\nTEST_CERT\n-----END CERTIFICATE-----"
      privkey_pem = "-----BEGIN PRIVATE KEY-----\nTEST_KEY\n-----END PRIVATE KEY-----"
      chain_pem = "-----BEGIN CERTIFICATE-----\nTEST_CHAIN\n-----END CERTIFICATE-----"

      checksum = :crypto.hash(:sha256, cert_pem <> privkey_pem <> chain_pem)

      valid_bundle = %{
        domain: "example.com",
        cert_pem: cert_pem,
        privkey_pem: privkey_pem,
        chain_pem: chain_pem,
        checksum: checksum,
        generated_at: DateTime.utc_now()
      }

      result = CertificateManager.receive_certificates(valid_bundle)
      assert :ok = result

      # Verify files were written
      cert_dir = Path.join([temp_dir, "certs", "example.com"])
      assert File.exists?(Path.join(cert_dir, "cert.pem"))
      assert File.exists?(Path.join(cert_dir, "privkey.pem"))
      assert File.exists?(Path.join(cert_dir, "chain.pem"))

      # Verify file contents
      assert File.read!(Path.join(cert_dir, "cert.pem")) == cert_pem
      assert File.read!(Path.join(cert_dir, "privkey.pem")) == privkey_pem
      assert File.read!(Path.join(cert_dir, "chain.pem")) == chain_pem

      GenServer.stop(pid)
      System.delete_env("SITE_ENCRYPT_DB")
    end

    test "primary cannot receive certificates", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

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

      result = CertificateManager.receive_certificates(cert_bundle)
      assert {:error, :primary_cannot_receive} = result

      GenServer.stop(pid)
      System.delete_env("SITE_ENCRYPT_DB")
    end
  end

  describe "status reporting" do
    test "returns correct status for primary node", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

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
      assert status.db_folder == temp_dir
      assert status.last_sync == nil
      assert status.sync_failures == 0
      assert status.clustering_enabled == true

      GenServer.stop(pid)
      System.delete_env("SITE_ENCRYPT_DB")
    end

    test "returns correct status for secondary node", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

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
      System.delete_env("SITE_ENCRYPT_DB")
    end
  end

  describe "cert sync disabled" do
    test "cert sync can be disabled via config", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

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
      System.delete_env("SITE_ENCRYPT_DB")
    end
  end

  describe "trigger_sync" do
    test "primary can trigger manual sync", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-trigger-primary",
        peers: ["peer:9100"]
      )

      {:ok, pid} = CertificateManager.start_link([])

      # Create test certificates
      domain = "example.com"
      cert_dir = Path.join([temp_dir, "certs", domain])
      File.mkdir_p!(cert_dir)

      File.write!(Path.join(cert_dir, "cert.pem"), "CERT")
      File.write!(Path.join(cert_dir, "privkey.pem"), "KEY")
      File.write!(Path.join(cert_dir, "chain.pem"), "CHAIN")

      # Trigger sync (will fail since no actual peers connected, but shouldn't crash)
      result = CertificateManager.trigger_sync(domain)
      assert :ok = result

      GenServer.stop(pid)
      System.delete_env("SITE_ENCRYPT_DB")
    end

    test "secondary cannot trigger sync", %{temp_dir: temp_dir} do
      System.put_env("SITE_ENCRYPT_DB", temp_dir)

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
      System.delete_env("SITE_ENCRYPT_DB")
    end
  end
end
