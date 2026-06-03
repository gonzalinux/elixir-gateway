defmodule ElixirGateway.CertStoreTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.CertStore

  @table :cert_store

  setup do
    original_config = Application.get_env(:elixirgateway, :cert_store)
    ets_snapshot = :ets.tab2list(@table)

    on_exit(fn ->
      :ets.delete_all_objects(@table)
      :ets.insert(@table, ets_snapshot)

      if original_config do
        Application.put_env(:elixirgateway, :cert_store, original_config)
      else
        Application.delete_env(:elixirgateway, :cert_store)
      end
    end)

    :ok
  end

  describe "sni_fun/1 — exact match" do
    test "returns ssl opts for a registered domain" do
      ssl_opts = [certfile: "/fake/cert.pem", keyfile: "/fake/key.pem"]
      domain = "exact.cert-store-test.example"
      :ets.insert(@table, {domain, ssl_opts})

      assert CertStore.sni_fun(String.to_charlist(domain)) == ssl_opts
    end

    test "returns :undefined for an unknown domain when no dev certs and no ETS entry" do
      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: "/nonexistent/certbot",
        dev_cert_dir: "/nonexistent/dev/certs"
      )

      :ets.delete_all_objects(@table)

      assert CertStore.sni_fun(~c"unknown.cert-store-test.example") == :undefined
    end
  end

  describe "sni_fun/1 — wildcard match" do
    test "matches subdomain against a wildcard ETS entry" do
      ssl_opts = [certfile: "/fake/wildcard.pem", keyfile: "/fake/wildcard-key.pem"]
      :ets.insert(@table, {"*.wildcard-cert-store-test.example", ssl_opts})

      result = CertStore.sni_fun(~c"sub.wildcard-cert-store-test.example")

      assert result == ssl_opts
    end

    test "does not match the apex domain against its own wildcard entry" do
      ssl_opts = [certfile: "/fake/wildcard.pem", keyfile: "/fake/wildcard-key.pem"]
      :ets.insert(@table, {"*.apex-cert-store-test.example", ssl_opts})

      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: "/nonexistent/certbot",
        dev_cert_dir: "/nonexistent/dev/certs"
      )

      :ets.delete_all_objects(@table)
      :ets.insert(@table, {"*.apex-cert-store-test.example", ssl_opts})

      result = CertStore.sni_fun(~c"apex-cert-store-test.example")

      assert result == :undefined
    end

    test "deep subdomain falls through to wildcard lookup one level up" do
      ssl_opts = [certfile: "/fake/cert.pem", keyfile: "/fake/key.pem"]
      :ets.insert(@table, {"*.parent-cert-store-test.example", ssl_opts})

      # deep.sub.parent… strips first label → "sub.parent…" → lookup "*.sub.parent…" → nil
      # then dev_fallback (priv/certs exists) → not :undefined but still not the wildcard opts
      # What we test here: the wildcard opts are NOT returned for a two-level subdomain
      result = CertStore.sni_fun(~c"deep.sub.parent-cert-store-test.example")

      refute result == ssl_opts
    end
  end

  describe "sni_fun/1 — dev_fallback" do
    test "returns priv/certs opts when no ETS entry matches" do
      :ets.delete_all_objects(@table)

      # Default config points dev_cert_dir to priv/certs which has cert.pem and key.pem
      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: "/nonexistent/certbot",
        dev_cert_dir: "priv/certs"
      )

      result = CertStore.sni_fun(~c"nomatch.dev-fallback-test.example")

      assert is_list(result)
      assert Keyword.get(result, :certfile) =~ "cert.pem"
      assert Keyword.get(result, :keyfile) =~ "key.pem"
    end

    test "dev_fallback is skipped when dev_cert_dir has no cert files" do
      :ets.delete_all_objects(@table)

      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: "/nonexistent/certbot",
        dev_cert_dir: "/nonexistent/dev-certs"
      )

      assert CertStore.sni_fun(~c"nomatch.no-fallback-test.example") == :undefined
    end
  end

  describe "days_until_expiry/1" do
    test "returns :no_cert when the cert file does not exist" do
      temp_dir = Path.join(System.tmp_dir!(), "cert_expiry_test_#{:rand.uniform(999_999)}")
      File.mkdir_p!(temp_dir)

      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: temp_dir,
        dev_cert_dir: "priv/certs"
      )

      result = CertStore.days_until_expiry("missing.domain.example")

      assert result == :no_cert
    after
      File.rm_rf!(Path.join(System.tmp_dir!(), "cert_expiry_test_*"))
    end

    test "returns integer days when a valid cert exists" do
      temp_dir = Path.join(System.tmp_dir!(), "cert_expiry_valid_#{:rand.uniform(999_999)}")
      live_dir = Path.join(temp_dir, "live/testdomain.example")
      File.mkdir_p!(live_dir)

      cert_path = Path.join(live_dir, "fullchain.pem")
      generate_self_signed_cert(cert_path, "testdomain.example", 90)

      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: temp_dir,
        dev_cert_dir: "priv/certs"
      )

      result = CertStore.days_until_expiry("testdomain.example")

      assert is_integer(result)
      assert result > 0

      File.rm_rf!(temp_dir)
    end

    test "returns :no_cert when fullchain.pem is not a valid cert" do
      temp_dir = Path.join(System.tmp_dir!(), "cert_expiry_bad_#{:rand.uniform(999_999)}")
      live_dir = Path.join(temp_dir, "live/baddomain.example")
      File.mkdir_p!(live_dir)
      File.write!(Path.join(live_dir, "fullchain.pem"), "not a real cert")

      Application.put_env(:elixirgateway, :cert_store,
        certbot_config_dir: temp_dir,
        dev_cert_dir: "priv/certs"
      )

      assert CertStore.days_until_expiry("baddomain.example") == :no_cert

      File.rm_rf!(temp_dir)
    end
  end

  # Generates a self-signed EC cert at the given path using the system's openssl.
  defp generate_self_signed_cert(cert_path, cn, days) do
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
