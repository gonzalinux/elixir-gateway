defmodule ElixirGatewayWeb.Plugs.AcmeChallengePlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias ElixirGatewayWeb.Plugs.AcmeChallengePlug

  setup do
    original_config = Application.get_env(:elixirgateway, :cert_store)
    webroot = Path.join(System.tmp_dir!(), "acme_test_#{:rand.uniform(999_999)}")
    challenge_dir = Path.join(webroot, ".well-known/acme-challenge")
    File.mkdir_p!(challenge_dir)

    Application.put_env(:elixirgateway, :cert_store, acme_webroot: webroot)

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :cert_store, original_config)
      else
        Application.delete_env(:elixirgateway, :cert_store)
      end

      File.rm_rf!(webroot)
    end)

    {:ok, webroot: webroot, challenge_dir: challenge_dir}
  end

  defp call_plug(path_info) do
    conn(:get, "/")
    |> Map.put(:path_info, path_info)
    |> AcmeChallengePlug.call([])
  end

  describe "token validation" do
    test "serves 200 with file contents when token is valid and file exists", %{
      challenge_dir: challenge_dir
    } do
      token = "valid-token_ABC123"
      File.write!(Path.join(challenge_dir, token), "#{token}.key-auth")

      conn = call_plug([token])

      assert conn.status == 200
      assert conn.halted
      assert conn.resp_body == "#{token}.key-auth"
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "returns 404 when token is valid format but file does not exist" do
      conn = call_plug(["validtoken-but-missing_ABC123"])

      assert conn.status == 404
      assert conn.halted
    end

    test "returns 400 when token contains a forward slash" do
      conn = call_plug(["invalid/token"])

      assert conn.status == 400
      assert conn.halted
    end

    test "returns 400 when token contains a dot" do
      conn = call_plug(["invalid.token"])

      assert conn.status == 400
      assert conn.halted
    end

    test "returns 400 when token contains a space" do
      conn = call_plug(["invalid token"])

      assert conn.status == 400
      assert conn.halted
    end

    test "returns 400 when token contains an equals sign (padding)" do
      conn = call_plug(["token=="])

      assert conn.status == 400
      assert conn.halted
    end

    test "accepts tokens with hyphens and underscores" do
      conn = call_plug(["token-with_dashes_and-underscores-but-no-file"])

      # File won't exist, so 404 — but not 400, meaning the token was accepted
      assert conn.status == 404
    end
  end

  describe "path routing" do
    test "returns 404 for empty path_info" do
      conn = call_plug([])

      assert conn.status == 404
      assert conn.halted
    end

    test "returns 404 for multiple path segments" do
      conn = call_plug(["segment1", "segment2"])

      assert conn.status == 404
      assert conn.halted
    end

    test "always halts the connection" do
      conn = call_plug([])

      assert conn.halted
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert AcmeChallengePlug.init([]) == []
      assert AcmeChallengePlug.init(some: :opt) == [some: :opt]
    end
  end
end
