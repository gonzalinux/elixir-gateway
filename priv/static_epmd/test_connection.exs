#!/usr/bin/env elixir

# Test script to verify StaticEpmd is working during node connection

IO.puts("=== Testing StaticEpmd Connection ===")
IO.puts("Node: #{inspect(Node.self())}")
IO.puts("EPMD module: #{inspect(:net_kernel.epmd_module())}")

# Try to connect to a node
target = :"local2_9200@127.0.0.1"
IO.puts("\nAttempting to connect to: #{inspect(target)}")

# Enable verbose net_kernel logging
:logger.set_primary_config(:level, :debug)
:logger.set_module_level(:net_kernel, :all)
:logger.set_module_level(:inet, :all)

result = Node.connect(target)
IO.puts("Connection result: #{inspect(result)}")

if result == false do
  IO.puts("\n=== Troubleshooting ===")
  IO.puts("Connected nodes: #{inspect(Node.list())}")
  IO.puts("Net kernel info: #{inspect(:net_kernel.nodes_info())}")

  # Try to manually call StaticEpmd
  IO.puts("\n=== Manual EPMD call ===")
  epmd_result = :"Elixir.StaticEpmd".port_please('local2_9200', {127, 0, 0, 1})
  IO.puts("EPMD result: #{inspect(epmd_result)}")
end

Process.sleep(2000)
