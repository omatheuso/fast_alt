defmodule FastAlt.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FastAltWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:fast_alt, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FastAlt.PubSub},
      {Task.Supervisor, name: FastAlt.TaskSupervisor},
      {Nx.Serving,
       serving: FastAlt.MarkdownServing.serving(), name: FastAlt.MarkdownServing, batch_size: 1},
      FastAltWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FastAlt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FastAltWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
