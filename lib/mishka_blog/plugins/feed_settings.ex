# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedSettings do
  @moduledoc """
  Registers the feed settings with the Settings page through the `settings:register`
  mishka_installer hook, in a **Feeds** group under the **Blog** tab, each with a global default a
  site may override (`scope: :both`): `blog.feeds.enabled`, `blog.feeds.items` and
  `blog.feeds.full_content`. `MishkaBlog.Feeds` reads them. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 45}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Settings

  @impl true
  def call(%{definitions: definitions} = data) do
    {:reply, %{data | definitions: definitions ++ definitions()}}
  end

  defp definitions do
    [
      Settings.define("blog.feeds.enabled", :boolean,
        default: true,
        category: "blog",
        group: gettext_noop("Feeds"),
        scope: :both,
        source: :plugin,
        label: gettext_noop("Serve RSS, Atom and JSON feeds"),
        description:
          gettext_noop(
            "Readers can subscribe to the blog's newest posts at /feed, /feed/atom and /feed.json, and to a category's, tag's or author's."
          )
      ),
      Settings.define("blog.feeds.items", :integer,
        default: 20,
        min: 1,
        max: 100,
        category: "blog",
        group: gettext_noop("Feeds"),
        scope: :both,
        source: :plugin,
        label: gettext_noop("Posts in a feed"),
        description: gettext_noop("How many of the newest posts a feed lists.")
      ),
      Settings.define("blog.feeds.full_content", :boolean,
        default: true,
        category: "blog",
        group: gettext_noop("Feeds"),
        scope: :both,
        source: :plugin,
        label: gettext_noop("Put the whole post in a feed"),
        description:
          gettext_noop(
            "Off lists only each post's title and summary, so a reader visits the site to read it."
          )
      )
    ]
  end
end
