# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedEntries do
  @moduledoc """
  Gives the blog's newest posts to a site's RSS, Atom and JSON feeds, through the `feeds:entries`
  mishka_installer hook `MishkaCmsCore.Feeds` fires when it builds one. A post, a category, a tag or
  a blogger written drops the site's kept feeds, because those resources list
  `MishkaCmsCore.Runtime.Resources.Notifiers.FeedRefresh`.

  ## What is published

  The posts a visitor who is not signed in may open: the read is `:public_list` as a guest, on the
  payload's site, so a draft, a scheduled post, an archived one, one still to be published, a post
  of another site, one locked to permissions or filed only under a locked category is never in a
  feed. They are the posts in the feed's language, newest first, as many as the payload's `limit`,
  in ONE read that loads only what an entry shows: the post's text as the site draws it
  (`rendered_content`, which the content is sanitized into when it is saved, so it is not
  sanitized again) only while the payload says the content is shown, its categories' names and its
  authors' names.

  An entry is at the address of the page that shows posts (`MishkaBlog.Address.of/3`), so a site
  that moved from WordPress and names its posts `/:year/:monthnum/:slug` is read at those. A post
  that address cannot be made for is left out. Its summary is its excerpt, else the first 300
  characters of its text.

  ## The feed of a term

  The `scope` of the payload is `{"category", slug}`, `{"tag", slug}` or `{"author", slug}`: the
  feed holds the posts filed under that category or tag, or written by that blogger, and its `title`
  is the term's name. A term the site does not have in that language (a blogger has no language), or
  one a guest may not open, is not named, and the feed does not exist. The page of the term is the
  feed's `link`, and the blog's front page the site feed's.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "feeds:entries", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{Address, Blogger, BlogPost, Collection, Tag}
  alias MishkaCmsCore.Feeds.Entry
  alias MishkaCmsCore.PlainText

  @summary_length 300

  # Each kind of term a feed is scoped by: its resource, the field it is named by and whether it has
  # a language of its own.
  @terms %{
    "category" => {Collection, :name, true},
    "tag" => {Tag, :name, true},
    "author" => {Blogger, :display_name, false}
  }

  @impl true
  def call(%{site: %{id: site_id}, scope: scope, language: language} = data)
      when is_binary(site_id) and is_binary(language) do
    case term(scope, site_id, language) do
      {:ok, title, link, scoped} ->
        {:reply,
         %{
           data
           | entries: data.entries ++ entries(data, scoped),
             title: title || data.title,
             link: link || data.link
         }}

      :error ->
        {:reply, data}
    end
  end

  def call(data), do: {:reply, data}

  defp term(:site, site_id, language),
    do: {:ok, nil, Address.page_url("blog:home", language, site_id), nil}

  defp term({kind, slug}, site_id, language) when is_map_key(@terms, kind) do
    {resource, name, language?} = Map.fetch!(@terms, kind)

    query =
      resource
      |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.Query.select([:slug, name])

    query = if language?, do: language_scoped(query, language), else: query

    case Ash.read(query, actor: nil, tenant: site_id, page: [limit: 1]) do
      {:ok, %{results: [term | _]}} ->
        {:ok, Map.fetch!(term, name), Address.of(term, site_id, language), {kind, slug}}

      _unknown ->
        :error
    end
  end

  defp term(_scope, _site_id, _language), do: :error

  defp language_scoped(query, language) do
    query
    |> Ash.Query.ensure_selected([:language])
    |> Ash.Query.filter(language == ^language)
  end

  defp entries(%{site: %{id: site_id}, language: language} = data, scoped) do
    now = DateTime.utc_now()
    full? = data.full_content?

    BlogPost
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language == ^language and published_at <= ^now)
    |> scoped(scoped)
    |> Ash.Query.sort(published_at: :desc, id: :desc)
    |> Ash.Query.select([
      :title,
      :slug,
      :language,
      :excerpt,
      :content,
      :featured_image_url,
      :published_at,
      :updated_at,
      :number
    ])
    |> Ash.Query.load(
      [
        collections: Ash.Query.select(Collection, [:name]),
        bloggers: Ash.Query.select(Blogger, [:display_name])
      ] ++
        Address.loads(BlogPost, site_id, language) ++ if(full?, do: [:rendered_content], else: [])
    )
    |> Ash.read!(actor: nil, tenant: site_id, page: [limit: data.limit])
    |> Map.fetch!(:results)
    |> Enum.flat_map(&entry(&1, site_id, full?))
  end

  defp scoped(query, nil), do: query

  defp scoped(query, {"category", slug}),
    do: Ash.Query.filter(query, exists(collections, slug == ^slug))

  defp scoped(query, {"tag", slug}),
    do: Ash.Query.filter(query, exists(tags, slug == ^slug))

  defp scoped(query, {"author", slug}),
    do: Ash.Query.filter(query, exists(bloggers, slug == ^slug))

  defp entry(post, site_id, full?) do
    case Address.of(post, site_id) do
      nil ->
        []

      path ->
        [
          %Entry{
            path: path,
            title: post.title,
            summary: summary(post),
            content_html: if(full?, do: post.rendered_content),
            published_at: post.published_at,
            updated_at: post.updated_at,
            authors: Enum.map(post.bloggers, & &1.display_name),
            categories: Enum.map(post.collections, & &1.name),
            image_url: post.featured_image_url,
            language: post.language
          }
        ]
    end
  end

  defp summary(%{excerpt: excerpt}) when is_binary(excerpt) and excerpt != "", do: excerpt

  defp summary(%{content: content}) when is_binary(content) do
    content
    |> PlainText.from_html()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @summary_length)
  end

  defp summary(_post), do: nil
end
