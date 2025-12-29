defmodule StaticEpmd do
  # THIS MUST BE PRECOMPILED BEFORE STARTING THE SERVER
  # To compile this:
  # elixirc static_epmd.ex

  # These are the mandatory callbacks for the EPMD protocol.
  # We are implementing the 'erl_epmd' behavior.

  # 1. Start Link: We don't need a daemon process, so we ignore this.
  def start_link, do: :ignore

  # 2. Register Node: We don't register anything; we rely on static ports.
  # We return a random "creation" number (1-3) to satisfy the protocol.
  def register_node(name, port), do: register_node(name, port, :inet)
  def register_node(_name, _port, _driver), do: {:ok, :rand.uniform(3)}

  # 3. Names: Used for debugging (e.g., net_adm:names()). We return empty.
  def names(_host), do: {:ok, ["StaticNames"]}

  # 4. Port Please: The core logic.
  # 'name' comes in as a charlist (e.g. 'nodeA_9100'), NOT a string.
  # IMPORTANT: Must use pure Erlang functions, not Elixir stdlib
  def port_please(name, _ip) when is_list(name) do
    # Split charlist by underscore manually (95 is ASCII for '_')
    # e.g. 'local2_9200' -> ['local2', '9200']
    parts = split_charlist(name, ?_)

    result = case parts do
      [] ->
        :io.format("[StaticEpmd] ERROR: Empty name~n")
        :noport
      parts_list ->
        # Get the last part (should be the port)
        port_part = :lists.last(parts_list)
        parsed = parse_port_charlist(port_part)

        # Log for debugging
        :io.format("[StaticEpmd] Resolving '~s' parts=~p -> ~p~n", [name, parts, parsed])
        parsed
    end

    result
  end

  # Fallback for non-list input
  def port_please(name, _ip) do
    :io.format("[StaticEpmd] ERROR: Invalid name type: ~p~n", [name])
    :noport
  end

  # Manually split a charlist by a delimiter
  defp split_charlist(list, delimiter) do
    split_charlist(list, delimiter, [], [])
  end

  defp split_charlist([], _delimiter, current, acc) do
    # Add the last part and reverse to get correct order
    :lists.reverse([:lists.reverse(current) | acc])
  end

  defp split_charlist([char | rest], delimiter, current, acc) when char == delimiter do
    # Found delimiter, save current part and start new one
    split_charlist(rest, delimiter, [], [:lists.reverse(current) | acc])
  end

  defp split_charlist([char | rest], delimiter, current, acc) do
    # Regular character, add to current part
    split_charlist(rest, delimiter, [char | current], acc)
  end

  # Helper to parse the port charlist safely
  # Uses pure Erlang functions for compatibility
  defp parse_port_charlist(port_chars) when is_list(port_chars) do
    # Try to convert charlist to integer
    # e.g. '9200' -> 9200
    try do
      port = :erlang.list_to_integer(port_chars)
      {:port, port, 6}  # 6 is the protocol version for OTP 23+
    rescue
      ArgumentError ->
        :io.format("[StaticEpmd] ERROR: Invalid port format: ~p~n", [port_chars])
        :noport
    end
  end

  defp parse_port_charlist(_), do: :noport


  # 6. Address Please: Resolves hostname and returns IP + port
  def address_please(name, host, address_family) when is_list(name) do
    :io.format("[StaticEpmd] address_please called for: ~s@~s~n", [name, host])

    # First resolve the hostname to an IP
    case :inet.getaddr(host, address_family) do
      {:ok, ip} ->
        :io.format("[StaticEpmd] Resolved ~s to ~p~n", [host, ip])

        # Then get the port from the name
        parts = split_charlist(name, ?_)

        case parts do
          [] ->
            {:error, :nxdomain}
          parts_list ->
            port_part = :lists.last(parts_list)

            try do
              port = :erlang.list_to_integer(port_part)
              :io.format("[StaticEpmd] Returning: ip=~p port=~p version=6~n", [ip, port])
              {:ok, ip, port, 6}
            rescue
              ArgumentError ->
                {:error, :nxdomain}
            end
        end

      {:error, reason} ->
        :io.format("[StaticEpmd] Failed to resolve ~s: ~p~n", [host, reason])
        {:error, reason}
    end
  end

  def address_please(name, _host, _address_family) do
    :io.format("[StaticEpmd] ERROR: Invalid name type in address_please: ~p~n", [name])
    {:error, :nxdomain}
  end
end
