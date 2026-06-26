defmodule ElixirGateway.Service do
  @enforce_keys [:name, :target]
  defstruct [
    :name,
    :target,
    domains: [],
    ssl: true,
    force_https: true,
    paths: [],
    ddns: []
  ]
end
