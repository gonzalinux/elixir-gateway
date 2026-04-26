defmodule ElixirGateway.Cluster.RPC do
  @callback handle_rpc(message :: term()) :: term()

  defmacro __using__(_opts) do
    quote do
      @behaviour ElixirGateway.Cluster.RPC
      def rpc_call(node, message, timeout \\ 30_000) do
        ElixirGateway.Cluster.RPC.__send_rpc__(node, __MODULE__, message, timeout)
      end

      defoverridable(rpc_call: 3)
    end
  end

  def receive_rpc(module, message) do
    module.handle_rpc(message)
  end

  def __send_rpc__(node, module, message, timeout \\ 30_000) do
    case :rpc.call(node, __MODULE__, :receive_rpc, [module, message], timeout) do
      {:badrpc, :nodedown} -> {:error, :node_down}
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end
end
