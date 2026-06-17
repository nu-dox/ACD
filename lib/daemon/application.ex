defmodule Daemon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Daemon.Finch, pools: %{
        :default => [
          protocols: [:http1],
          size: 10,
          conn_opts: [
            transport_opts: [
              versions: [:"tlsv1.2"],
              verify: :verify_peer,
              cacertfile: CAStore.file_path()
            ]
          ]
        ]
      }},
      {Phoenix.PubSub, name: Daemon.PubSub},
      {Registry, keys: :unique, name: Daemon.SessionRegistry},
      {DynamicSupervisor, name: Daemon.SessionSupervisor, strategy: :one_for_one},
      {Bandit, plug: Daemon.HTTP.Router, port: 4000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Daemon.Supervisor)
  end
end
