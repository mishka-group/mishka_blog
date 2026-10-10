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

  # Installs this extension onto a site when an admin asks for it — the `installer:extension:install`
  # event. Subscribing is also how the installer's own registry learns this extension exists, so
  # there is nothing else to register: see `MishkaCmsCore.Install.Extensions`.
  @provision_plugins [
    MishkaBlog.Plugins.Installer
  ]

  # Adds the blog's posts, categories and tags to each site's sitemap (a `seo:sitemap:urls` plugin),
  # names them as kinds of record a page can show (a `runtime:page:records` plugin), and gives each
  # its own head on the page that shows it (a `runtime:page:seo` plugin).
  @seo_plugins [
    MishkaBlog.Plugins.SitemapUrls,
    MishkaBlog.Plugins.PageRecords,
    MishkaBlog.Plugins.PageSeo
  ]

  # Each record's share card looked at again after the record is saved, on its own
  # `blog:<resource>:after_save` event (`MishkaCmsCore.Runtime.ShareCard`).
  @share_card_plugins [
    MishkaBlog.Plugins.PostShareCard,
    MishkaBlog.Plugins.CollectionShareCard,
    MishkaBlog.Plugins.TagShareCard,
    MishkaBlog.Plugins.BloggerShareCard,
    MishkaBlog.Plugins.TeamShareCard
  ]

  # Names the components the site's posts draw, so its stylesheet carries them (a
  # `runtime:compile:content_components` plugin).
  @runtime_plugins [
    MishkaBlog.Plugins.ContentComponents
  ]

  # Each code block of a post being written is lexed in a task of its own under this supervisor — see
  # `MishkaBlog.Resources.Changes.HighlightCode`.
  @highlight_supervisor {Task.Supervisor, name: MishkaBlog.HighlightSupervisor}

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do:
      @dashboard_widgets ++
        @notify_plugins ++
        @settings_plugins ++
        @sidebar_menus ++
        @provision_plugins ++ @seo_plugins ++ @share_card_plugins ++ @runtime_plugins

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaBlog.Supervisor]
    Supervisor.start_link([@highlight_supervisor | plugins()], opts)
  end
end
