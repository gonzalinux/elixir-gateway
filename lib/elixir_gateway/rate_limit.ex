defmodule ElixirGateway.RateLimit do
  use Hammer, backend: :ets
end
