defmodule Mix.Tasks.ElixirGateway.Gen.ClusterSecret do
  @moduledoc """
  Generates a secure random secret for cluster authentication.

  All nodes in a cluster must share the same secret for encrypted communication.

  ## Usage

      mix elixir_gateway.gen.cluster_secret

  This will output a secure random hex string that you can use as your CLUSTER_SECRET.

  ## Example

      $ mix elixir_gateway.gen.cluster_secret
      a1b2c3d4e5f6...

      # Set in environment
      export CLUSTER_SECRET=a1b2c3d4e5f6...

      # Or in config/runtime.exs
      config :elixirgateway, :cluster,
        secret: System.get_env("CLUSTER_SECRET")

  ## Alternative Method

  You can also generate a secret using OpenSSL:

      openssl rand -hex 32
  """

  use Mix.Task

  @shortdoc "Generates a cluster secret for node authentication"

  @impl Mix.Task
  def run(_args) do
    secret = ElixirGateway.Cluster.Secret.generate()

    Mix.shell().info("""

    Generated cluster secret (keep this secure):

    #{secret}

    Use this secret on all nodes in your cluster:

    1. Set as environment variable:
       export CLUSTER_SECRET=#{secret}

    2. Configure in config/runtime.exs:
       config :elixirgateway, :cluster,
         enabled: true,
         secret: System.get_env("CLUSTER_SECRET"),
         node_name: System.get_env("NODE_NAME"),
         peers: ["other-node.example.com:9100"]

    IMPORTANT: All nodes must use the same secret!
    """)
  end
end
