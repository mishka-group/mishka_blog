# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Routes do
  @moduledoc """
  Extension routes for MishkaBlog: the admin pages, and the feeds as API routes (`routes(:api)`).

  The feeds are `/feed` (also `/feed.rss`), `/feed/atom`, `/feed.json` and the feed of a term, `/feed/:kind/:key` with
  `/atom` or `/json` after it, or a nested term by its whole chain,
  `/feed/category/design/accessibility` (last, so it takes only what the others leave), each also
  under a language, `/:lang/feed`. A reader asks for them whatever `Accept` it sends, so they answer
  any (`accepts: :any`), and the format is the route's own (`feed_format`). See `MishkaBlog.Feeds`.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/blog", MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, :index},
      {:live, "/blog/posts", MishkaBlogWeb.Live.Admin.Dashboard.Post.Index, :index},
      {:live, "/blog/collections", MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index, :index},
      {:live, "/blog/tags", MishkaBlogWeb.Live.Admin.Dashboard.Tag.Index, :index},
      {:live, "/blog/bloggers", MishkaBlogWeb.Live.Admin.Dashboard.Blogger.Index, :index},
      {:live, "/blog/comments", MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index, :index},
      {:live, "/blog/teams", MishkaBlogWeb.Live.Admin.Dashboard.Team.Index, :index},
      {:live, "/blog/analytics", MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index, :index}
    ]
  end

  def routes(:public), do: []

  def routes(:api) do
    for prefix <- ["", "/:lang"],
        {format, path} <- [
          {:rss, "/feed"},
          {:rss, "/feed.rss"},
          {:atom, "/feed/atom"},
          {:json, "/feed.json"},
          {:rss, "/feed/:kind/:key"},
          {:atom, "/feed/:kind/:key/atom"},
          {:json, "/feed/:kind/:key/json"},
          {:rss, "/feed/:kind/*chain"}
        ] do
      {:get, prefix <> path, MishkaBlogWeb.FeedController, :show,
       private: %{accepts: :any, feed_format: format}}
    end
  end

  def routes(_), do: []
end
