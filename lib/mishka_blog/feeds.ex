# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Feeds do
  @moduledoc """
  The blog's RSS 2.0, Atom 1.0 and JSON Feed 1.1 feeds: of a site's newest posts, and of a
  category's, a tag's or a blogger's. `MishkaBlogWeb.FeedController` serves them at the routes
  `MishkaBlogWeb.Routes.routes(:api)` declares, the head of a site's pages names them
  (`MishkaBlog.Plugins.FeedLinks`), and `blog-post-list` and `blog-post-detail` link them.

  ## Addresses

  `path/4` writes them, in the language prefix the site's URL mode gives (`/fa/feed`):

      /feed                        RSS 2.0, the site
      /feed/atom                   Atom 1.0
      /feed.json                   JSON Feed 1.1
      /feed/category/elixir        RSS 2.0 of a term; /atom and /json after it for the others
      /feed/category/design/a11y   a nested category by its whole chain

  The kinds of term are `category`, `tag` and `author`.

  ## Building and keeping

  A feed is built by `MishkaBlog.BlogPost`'s generic `:feed` action
  (`MishkaBlog.Resources.Actions.Feed`), in the three formats from one read, and kept in
  `MishkaCmsCore.Runtime.States.AssetsState` under the site, the language, the scope and the
  settings it was built with. A request builds it again when none is kept or the one kept is older
  than five minutes, which also covers a post a database trigger made live, a change on another node
  and a change to the site's title. A write to a post, a category, a tag or a blogger drops the
  site's feeds (`invalidate/1`, called by `MishkaBlog.Resources.Notifiers.FeedRefresh`). A feed with
  no entry is built on every request and never kept.

  ## Settings

  Under the Blog tab (`MishkaBlog.Plugins.FeedSettings`):

    * `blog.feeds.enabled` - the site's feeds are served at all, default on;
    * `blog.feeds.items` - how many entries, 1 to 100, default 20;
    * `blog.feeds.full_content` - whether the HTML of each post is in the feed or only its summary,
      default on.
  """

  alias MishkaBlog.Feeds.Renderer
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Settings

  @prefix "blog_feed:"
  @default_items 20
  @max_items 100

  @typedoc "The feed of the whole site, or of a term: its kind and key as they are in the address."
  @type scope :: :site | {String.t(), String.t()}

  @typedoc "A feed in one format, as it is kept and served."
  @type document :: %{
          body: binary(),
          etag: String.t(),
          last_modified: String.t(),
          content_type: String.t()
        }

  @doc "The kinds of term a feed is scoped by."
  @spec kinds() :: [String.t()]
  def kinds, do: ~w(category tag author)

  @doc "The prefix of every `AssetsState` type a feed is kept under."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Whether the site serves feeds at all: its `blog.feeds.enabled` setting."
  @spec enabled?(String.t() | nil) :: boolean()
  def enabled?(site_id), do: Settings.get("blog.feeds.enabled", true, site_id) == true

  @doc """
  What a feed of the site holds: `%{items: 1..100, full_content?: boolean}`, from its
  `blog.feeds.items` and `blog.feeds.full_content` settings.
  """
  @spec settings(String.t()) :: %{items: pos_integer(), full_content?: boolean()}
  def settings(site_id) do
    items =
      case Settings.get("blog.feeds.items", @default_items, site_id) do
        items when is_integer(items) -> items |> max(1) |> min(@max_items)
        _other -> @default_items
      end

    %{items: items, full_content?: Settings.get("blog.feeds.full_content", true, site_id) == true}
  end

  @doc """
  The path of a feed on the site, in the language prefix its URL mode gives, or `nil` for a language
  the site does not have.

      Feeds.path(:site, :atom, "fa", site_id)                  #=> "/fa/feed/atom"
      Feeds.path({"category", "elixir"}, :rss, "en", site_id)  #=> "/feed/category/elixir"
  """
  @spec path(scope(), Renderer.format(), String.t() | nil, String.t()) :: String.t() | nil
  def path(scope, format, language, site_id) do
    {pattern, captures} = pattern(scope, format)
    Languages.url(pattern, Map.put(captures, Languages.capture(), language), site_id)
  end

  defp pattern(:site, :rss), do: {"/:lang/feed", %{}}
  defp pattern(:site, :atom), do: {"/:lang/feed/atom", %{}}
  defp pattern(:site, :json), do: {"/:lang/feed.json", %{}}

  defp pattern({kind, key}, :rss), do: {"/:lang/feed/:kind/:key", %{"kind" => kind, "key" => key}}

  defp pattern({kind, key}, format),
    do: {"/:lang/feed/:kind/:key/#{format}", %{"kind" => kind, "key" => key}}

  @doc """
  The feed `scope` of `site` in `language`, in `format`, through `MishkaBlog.BlogPost`'s `:feed`
  action. `:error` when the site's feeds are off or the scope's term is not one a guest may open in
  that language.
  """
  @spec fetch(map(), scope(), String.t(), Renderer.format()) :: {:ok, document()} | :error
  def fetch(%{id: site_id}, scope, language, format) do
    with true <- enabled?(site_id),
         {:ok, %{} = documents} <-
           MishkaBlog.BlogPost
           |> Ash.ActionInput.for_action(:feed, arguments(scope, language),
             actor: nil,
             tenant: site_id
           )
           |> Ash.run_action() do
      {:ok, Map.fetch!(documents, format)}
    else
      _unavailable -> :error
    end
  end

  defp arguments(:site, language), do: %{language: language}
  defp arguments({kind, key}, language), do: %{language: language, kind: kind, key: key}

  @doc """
  Drops every feed kept for the site, so the next request builds them again. A `nil` site drops
  nothing.
  """
  @spec invalidate(String.t() | nil) :: :ok
  def invalidate(site_id) when is_binary(site_id) do
    for type <- AssetsState.types(site_id), String.starts_with?(type, @prefix) do
      AssetsState.delete(site_id, type)
    end

    :ok
  end

  def invalidate(_site_id), do: :ok
end
