defmodule PdfToMd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PdfToMdWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pdf_to_md, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PdfToMd.PubSub},
      # Start a worker by calling: PdfToMd.Worker.start_link(arg)
      # {PdfToMd.Worker, arg},
      # Start to serve requests, typically the last entry
      PdfToMdWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PdfToMd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PdfToMdWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
