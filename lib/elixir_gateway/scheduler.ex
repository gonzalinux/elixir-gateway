defmodule ElixirGateway.Scheduler do
  @moduledoc """
  Quantum scheduler for periodic tasks.

  Currently handles:
  - Periodic IP change detection for DDNS updates
  """

  use Quantum, otp_app: :elixirgateway
end
