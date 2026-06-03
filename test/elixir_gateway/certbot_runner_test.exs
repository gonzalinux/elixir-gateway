defmodule ElixirGateway.CertbotRunnerTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.CertbotRunner

  describe "process registration" do
    test "GenServer is registered under its module name" do
      assert Process.whereis(CertbotRunner) != nil
    end

    test "registered process is alive" do
      pid = Process.whereis(CertbotRunner)
      assert Process.alive?(pid)
    end
  end

  describe "ensure_cert/1" do
    test "does not crash the server" do
      pid = Process.whereis(CertbotRunner)
      CertbotRunner.ensure_cert("test-domain.example")

      assert Process.alive?(pid)
    end

    test "accepts multiple domains without crashing" do
      pid = Process.whereis(CertbotRunner)
      CertbotRunner.ensure_cert("domain-a.example")
      CertbotRunner.ensure_cert("domain-b.example")
      CertbotRunner.ensure_cert("domain-c.example")

      # Give the GenServer time to process casts
      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "ensure_wildcard_cert/1" do
    test "does not crash the server" do
      pid = Process.whereis(CertbotRunner)
      CertbotRunner.ensure_wildcard_cert("wildcard-test.example")

      assert Process.alive?(pid)
    end
  end

  describe "mixed queue" do
    test "handles interleaved http-01 and dns-01 casts" do
      pid = Process.whereis(CertbotRunner)
      CertbotRunner.ensure_cert("mixed-http.example")
      CertbotRunner.ensure_wildcard_cert("mixed-dns.example")
      CertbotRunner.ensure_cert("mixed-http2.example")

      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end
end
