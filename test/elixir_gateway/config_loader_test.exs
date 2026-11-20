defmodule ElixirGateway.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.ConfigLoader

  setup do
    original_gateway = Application.get_env(:elixirgateway, :gateway)
    original_domains = Application.get_env(:elixirgateway, :letsencrypt_domains)
    original_dns_domains = Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains)
    original_cluster = Application.get_env(:elixirgateway, :cluster)

    on_exit(fn ->
      restore_or_delete(:gateway, original_gateway)
      restore_or_delete(:letsencrypt_domains, original_domains)
      restore_or_delete(:letsencrypt_wildcard_domains, original_dns_domains)
      restore_or_delete(:cluster, original_cluster)
    end)

    :ok
  end

  defp restore_or_delete(key, nil), do: Application.delete_env(:elixirgateway, key)
  defp restore_or_delete(key, value), do: Application.put_env(:elixirgateway, key, value)

  # --- YAML loading ---

  describe "load/0 from YAML file" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "gateway_test_#{System.unique_integer([:positive])}.yaml")

      System.put_env("GATEWAY_CONFIG_FILE", path)

      on_exit(fn ->
        System.delete_env("GATEWAY_CONFIG_FILE")
        File.rm(path)
      end)

      {:ok, path: path}
    end

    test "loads services from yaml", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
      """)

      ConfigLoader.load()

      services = Application.get_env(:elixirgateway, :gateway)[:services]
      assert services["myapp.com"] == "http://localhost:4000"
    end

    test "maps 'default' domain to 'default_any' key", %{path: path} do
      File.write!(path, """
      services:
        fallback:
          target: http://localhost:4000
          domains:
            - default
          ssl: false
      """)

      ConfigLoader.load()

      services = Application.get_env(:elixirgateway, :gateway)[:services]
      assert services["default_any"] == "http://localhost:4000"
    end

    test "collects ssl domains from services with ssl: true", %{path: path} do
      File.write!(path, """
      services:
        secure:
          target: http://localhost:4000
          domains:
            - "*.secure.com"
            - secure.com
          ssl: true
        insecure:
          target: http://localhost:5000
          domains:
            - insecure.com
          ssl: false
      """)

      ConfigLoader.load()

      domains = Application.get_env(:elixirgateway, :letsencrypt_domains)
      assert "secure.com" in domains
      refute "*.secure.com" in domains
      refute "insecure.com" in domains
    end

    test "dns_challenge on the wildcard entry requests DNS-01 for its apex", %{path: path} do
      File.write!(path, """
      services:
        garage:
          target: http://localhost:3900
          domains:
            - name: "*.garage.example.com"
              dns_challenge: true
            - garage.example.com
          ssl: true
      """)

      ConfigLoader.load()

      assert Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains) == [
               "garage.example.com"
             ]

      # the apex is covered by the DNS-01 cert, so it must not also be requested over HTTP-01
      assert Application.get_env(:elixirgateway, :letsencrypt_domains) == []
    end

    test "dns_challenge on both the wildcard and the apex requests one DNS-01 cert",
         %{path: path} do
      File.write!(path, """
      services:
        writeinone:
          target: http://localhost:9000
          domains:
            - name: "*.writeinone.example"
              dns_challenge: true
            - name: writeinone.example
              dns_challenge: true
            - blog.example.io
          ssl: true
      """)

      ConfigLoader.load()

      assert Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains) == [
               "writeinone.example"
             ]

      assert Application.get_env(:elixirgateway, :letsencrypt_domains) == ["blog.example.io"]
    end

    test "a wildcard without dns_challenge is not requested at all", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - "*.myapp.example"
          ssl: true
      """)

      ConfigLoader.load()

      assert Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains) == []
      assert Application.get_env(:elixirgateway, :letsencrypt_domains) == []
    end

    test "force_https defaults to true when ssl: true", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: true
      """)

      ConfigLoader.load()

      force_https = Application.get_env(:elixirgateway, :gateway)[:force_https]
      assert force_https["myapp.com"] == true
    end

    test "force_https can be disabled explicitly", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl:
            enabled: true
            force_https: false
      """)

      ConfigLoader.load()

      force_https = Application.get_env(:elixirgateway, :gateway)[:force_https]
      assert force_https["myapp.com"] == false
    end

    test "force_https is false when ssl is disabled", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
      """)

      ConfigLoader.load()

      force_https = Application.get_env(:elixirgateway, :gateway)[:force_https]
      assert force_https["myapp.com"] == false
    end

    test "substitutes env vars in string values", %{path: path} do
      System.put_env("TEST_TARGET_URL", "http://localhost:9999")
      on_exit(fn -> System.delete_env("TEST_TARGET_URL") end)

      File.write!(path, """
      services:
        myapp:
          target: "${TEST_TARGET_URL}"
          domains:
            - myapp.com
          ssl: false
      """)

      ConfigLoader.load()

      services = Application.get_env(:elixirgateway, :gateway)[:services]
      assert services["myapp.com"] == "http://localhost:9999"
    end

    test "raises when referenced env var is not set", %{path: path} do
      System.delete_env("MISSING_VAR")

      File.write!(path, """
      services:
        myapp:
          target: "${MISSING_VAR}"
          domains:
            - myapp.com
          ssl: false
      """)

      assert_raise RuntimeError, ~r/MISSING_VAR/, fn ->
        ConfigLoader.load()
      end
    end

    test "loads namecheap ddns entries", %{path: path} do
      System.put_env("DDNS_TOKEN", "secret123")
      on_exit(fn -> System.delete_env("DDNS_TOKEN") end)

      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
          ddns:
            provider: namecheap
            record: "@"
            domain: myapp.com
            token: "${DDNS_TOKEN}"
      """)

      ConfigLoader.load()

      cluster_config = Application.get_env(:elixirgateway, :cluster, [])
      domains = get_in(cluster_config, [:dns_failover, :domains])

      assert [%{host: "@", domain: "myapp.com", password: "secret123"}] = domains
    end

    test "leaves existing gateway config unchanged when the config file does not exist" do
      System.put_env("GATEWAY_CONFIG_FILE", "/nonexistent/path/gateway.yaml")

      Application.put_env(:elixirgateway, :gateway,
        services: %{"existing.com" => "http://existing"}
      )

      on_exit(fn -> System.delete_env("GATEWAY_CONFIG_FILE") end)

      ConfigLoader.load()

      assert Application.get_env(:elixirgateway, :gateway)[:services] == %{
               "existing.com" => "http://existing"
             }
    end
  end

  # --- timeouts ---

  describe "load/0 health checks" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "gateway_test_#{System.unique_integer([:positive])}.yaml")

      System.put_env("GATEWAY_CONFIG_FILE", path)

      on_exit(fn ->
        System.delete_env("GATEWAY_CONFIG_FILE")
        File.rm(path)
      end)

      {:ok, path: path}
    end

    test "builds one health check per service, keyed by service name", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: /health
          domains:
            - myapp.com
            - www.myapp.com
        other:
          target: http://localhost:5000
          health_path: /health
          domains:
            - other.com
      """)

      ConfigLoader.load()

      health = ConfigLoader.get_health_services()
      assert Map.keys(health) |> Enum.sort() == ["myapp", "other"]

      assert %{
               name: "myapp",
               target: "http://localhost:4000",
               domains: ["myapp.com", "www.myapp.com"]
             } = health["myapp"]
    end

    test "services without health_path get no health check", %{path: path} do
      File.write!(path, """
      services:
        checked:
          target: http://localhost:4000
          health_path: /health
          domains:
            - checked.com
        unchecked:
          target: http://localhost:5000
          domains:
            - unchecked.com
      """)

      ConfigLoader.load()

      health = ConfigLoader.get_health_services()
      assert Map.has_key?(health, "checked")
      refute Map.has_key?(health, "unchecked")
    end

    test "an empty health_path does not enable the health check", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: ""
          domains:
            - myapp.com
      """)

      ConfigLoader.load()

      assert ConfigLoader.get_health_services() == %{}
    end

    test "uses the configured health_path", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: /api/status
          domains:
            - myapp.com
      """)

      ConfigLoader.load()

      assert ConfigLoader.get_health_services()["myapp"].health_path == "/api/status"
    end

    test "health_domain is the shortest domain", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: /health
          domains:
            - www.myapp.com
            - myapp.com
      """)

      ConfigLoader.load()

      assert ConfigLoader.get_health_services()["myapp"].health_domain == "myapp.com"
    end

    test "a wildcard domain becomes health.<domain> for health_domain", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: /health
          domains:
            - "*.myapp.com"
      """)

      ConfigLoader.load()

      service = ConfigLoader.get_health_services()["myapp"]
      assert service.health_domain == "health.myapp.com"
      # domains keep the wildcard: they are the keys health is stored under
      assert service.domains == ["*.myapp.com"]
    end

    test "domains given as maps (dns_challenge) are normalized to their name", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          target: http://localhost:4000
          health_path: /health
          domains:
            - name: "*.myapp.com"
              dns_challenge: true
      """)

      ConfigLoader.load()

      assert ConfigLoader.get_health_services()["myapp"].domains == ["*.myapp.com"]
    end

    test "a default-only service has no health_domain", %{path: path} do
      File.write!(path, """
      services:
        fallback:
          target: http://localhost:4000
          health_path: /health
          domains:
            - default
      """)

      ConfigLoader.load()

      assert ConfigLoader.get_health_services()["fallback"].health_domain == nil
    end

    test "the default domain is stored as default_any, matching the routing key",
         %{path: path} do
      File.write!(path, """
      services:
        fallback:
          target: http://localhost:4000
          health_path: /health
          domains:
            - default
      """)

      ConfigLoader.load()

      # DomainRouter assigns "default_any" as :service_key, so health must use the same key
      assert ConfigLoader.get_health_services()["fallback"].domains == ["default_any"]
    end

    test "returns an empty map when there are no health checks" do
      Application.put_env(:elixirgateway, :gateway, services: %{})

      assert ConfigLoader.get_health_services() == %{}
    end
  end

  describe "load/0 timeout resolution" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "gateway_test_#{System.unique_integer([:positive])}.yaml")

      System.put_env("GATEWAY_CONFIG_FILE", path)

      on_exit(fn ->
        System.delete_env("GATEWAY_CONFIG_FILE")
        File.rm(path)
      end)

      {:ok, path: path}
    end

    test "falls back to the global default timeout", %{path: path} do
      File.write!(path, """
      timeout: 12
      services:
        myapp:
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
      """)

      ConfigLoader.load()

      [%{timeout: timeout}] =
        Application.get_env(:elixirgateway, :gateway)[:timeouts]["myapp.com"]

      assert timeout == 12
    end

    test "service-level timeout overrides the global default", %{path: path} do
      File.write!(path, """
      timeout: 12
      services:
        myapp:
          timeout: 5
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
      """)

      ConfigLoader.load()

      [%{timeout: timeout}] =
        Application.get_env(:elixirgateway, :gateway)[:timeouts]["myapp.com"]

      assert timeout == 5
    end

    test "path-level timeout overrides the service-level default", %{path: path} do
      File.write!(path, """
      services:
        myapp:
          timeout: 5
          target: http://localhost:4000
          domains:
            - myapp.com
          ssl: false
          paths:
            "/uploads":
              POST:
                timeout: 60
      """)

      ConfigLoader.load()

      matchers = Application.get_env(:elixirgateway, :gateway)[:timeouts]["myapp.com"]

      assert [%{method: "POST", timeout: 60}, %{method: ".*", timeout: 5}] = matchers
    end
  end
end
