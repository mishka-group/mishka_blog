defmodule MishkaBlog.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @dashboard_widgets [
    MishkaBlog.Dashboard.Widgets.RecentPosts,
    MishkaBlog.Dashboard.Widgets.DraftsScheduled,
    MishkaBlog.Dashboard.Widgets.CommentsModeration,
    MishkaBlog.Dashboard.Widgets.TopPosts,
    MishkaBlog.Dashboard.Widgets.Bloggers
  ]

  @doc """
  The blog's dashboard widget plugins. Each self-registers on the `dashboard:widgets` event, and
  `MishkaBlog.Dashboard.WidgetSettings` walks this same list to register each widget's own settings
  under the Blog tab — so the two can never disagree about which widgets exist.
  """
  @spec dashboard_widgets() :: [module()]
  def dashboard_widgets, do: @dashboard_widgets

  # Notification producers (a tenant and a master publish fire different events) + their Settings
  # toggle (mishka_installer hook plugins).
  @notify_plugins [
    MishkaBlog.Notifiers.PostPublished,
    MishkaBlog.Notifiers.PostMasterPublished,
    MishkaBlog.Notifiers.NotifySettings
  ]

  # Registers the blog widgets' settings under the Blog tab (a `settings:register` plugin).
  @settings_plugins [
    MishkaBlog.Dashboard.WidgetSettings
  ]

  # Contributes this extension's entry to the admin sidebar (a `sidebar:menus` plugin).
  @sidebar_menus [
    MishkaBlogWeb.SidebarMenu
  ]

  @doc """
  Every mishka_installer plugin this extension ships, and exactly what `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do: @dashboard_widgets ++ @notify_plugins ++ @settings_plugins ++ @sidebar_menus

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaBlog.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
