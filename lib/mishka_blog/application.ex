defmodule MishkaBlog.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def dashboard_widgets, do: []

  # Contributes this extension's entry to the admin sidebar (a `sidebar:menus` plugin).
  @sidebar_menus [
    MishkaBlogWeb.SidebarMenu
  ]

  @doc """
  Every mishka_installer plugin this extension ships, and exactly what `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins, do: @sidebar_menus

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaBlog.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
