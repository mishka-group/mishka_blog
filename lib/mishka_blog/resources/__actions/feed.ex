# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Actions.Feed do
  @moduledoc """
  Builds a site's feed in RSS 2.0, Atom 1.0 and JSON Feed 1.1 from one read of its posts, or
  returns the one kept for it while it is fresh (`MishkaBlog.Feeds`). The site is the action's
  tenant, and the result is `%{rss: document, atom: document, json: document}`.

  ## Usage

      action :feed, :map do
        argument :language, :string, allow_nil?: false
        argument :kind, :string
        argument :key, :string

        run MishkaBlog.Resources.Actions.Feed
      end

  With no `kind` it is the feed of the whole site. With one it is the feed of the `category`, the
  `tag` or the `author` whose slug is `key`, named by it; a term the site does not have, one of
  another language (a blogger has none) or one a guest may not open is
  `Ash.Error.Query.NotFound`, as is a kind that is not one of these.

  ## What is in it

  The posts a visitor who is not signed in may open: the read is `:public_list` as a guest, on the
  tenant, so a draft, a scheduled post, an archived one, one still to be published, a post of
  another site, one locked to permissions or filed only under a locked category is never in a feed.
  They are the posts in `language`, newest first, as many as `blog.feeds.items`, in ONE read that
  loads only what an entry shows: the post's text as the site draws it (`rendered_content`, which
  the content is sanitized into when it is saved, so it is not sanitized again) only while
  `blog.feeds.full_content` is on, its categories' names and its authors' names.

  An entry is at the address of the page that shows posts (`MishkaBlog.Address.of/3`), so a site
  that names its posts `/:year/:monthnum/:slug` is read at those, and a post that address cannot be
  made for is left out. Its summary is its excerpt, else the first 300 characters of its text. The
  feed's link is the blog's front page, or the term's page; its title is the site's, with the term's
  name after it.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias MishkaBlog.{Address, Blogger, BlogPost, Collection, Feeds, Tag}
  alias MishkaBlog.Feeds.Renderer
  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.PlainText
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Settings

  @ttl 300
  @summary_length 300

  # Each kind of term a feed is scoped by: its resource, the field it is named by and whether it has
  # a language of its own.
  @terms %{
    "category" => {Collection, :name, true},
    "tag" => {Tag, :name, true},
    "author" => {Blogger, :display_name, false}
  }

  @impl true
  def run(input, _opts, context) do
    site_id = context.tenant
    language = input.arguments.language
    scope = scope(input.arguments)
    settings = Feeds.settings(site_id)

    with {:ok, site} <- SiteState.get(site_id),
         {:ok, documents} <- kept_or_built(site, scope, language, settings) do
      {:ok, documents}
    else
      _unknown -> {:error, Ash.Error.Query.NotFound.exception(resource: BlogPost)}
    end
  end

  defp kept_or_built(site, scope, language, settings) do
    type = type(scope, language, settings)

    with :stale <- kept(site.id, type),
         {:ok, title, link} <- term(scope, site.id, language) do
      {:ok, build(site, scope, language, settings, {title, link}, type)}
    end
  end

  defp scope(%{kind: kind, key: key}) when is_binary(kind) and is_binary(key), do: {kind, key}
  defp scope(_arguments), do: :site

  defp type(scope, language, %{items: items, full_content?: full?}) do
    key = :erlang.term_to_binary({scope, language, items, full?}, [:deterministic])
    Feeds.prefix() <> Base.url_encode64(key, padding: false)
  end

  defp kept(site_id, type) do
    with {:ok, %{value: documents, updated_at: built_at}} <- AssetsState.get(site_id, type),
         true <- DateTime.diff(DateTime.utc_now(), built_at) < @ttl do
      {:ok, documents}
    else
      _stale -> :stale
    end
  end

  defp term(:site, site_id, language),
    do: {:ok, nil, Address.page_url("blog:home", language, site_id)}

  defp term({kind, slug}, site_id, language) when is_map_key(@terms, kind) do
    {resource, name, language?} = Map.fetch!(@terms, kind)

    query =
      resource
      |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.Query.select([:slug, name])
      |> language_scoped(language?, language)

    case Ash.read(query, actor: nil, tenant: site_id, page: [limit: 1]) do
      {:ok, %{results: [term | _]}} ->
        {:ok, Map.fetch!(term, name), Address.of(term, site_id, language)}

      _unknown ->
        :error
    end
  end

  defp term(_scope, _site_id, _language), do: :error

  defp language_scoped(query, false, _language), do: query

  defp language_scoped(query, true, language) do
    query
    |> Ash.Query.ensure_selected([:language])
    |> Ash.Query.filter(language == ^language)
  end

  defp build(site, scope, language, settings, {title, link}, type) do
    items =
      site.id
      |> posts(scope, language, settings)
      |> Enum.flat_map(&item(&1, site, settings.full_content?))

    documents = documents(site, scope, language, {title, link}, items)
    if items != [], do: keep(site.id, type, documents)
    documents
  end

  defp posts(site_id, scope, language, %{items: limit, full_content?: full?}) do
    now = DateTime.utc_now()

    BlogPost
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language == ^language and published_at <= ^now)
    |> scoped(scope)
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
    |> Ash.read!(actor: nil, tenant: site_id, page: [limit: limit])
    |> Map.fetch!(:results)
  end

  defp scoped(query, :site), do: query

  defp scoped(query, {"category", slug}),
    do: Ash.Query.filter(query, exists(collections, slug == ^slug))

  defp scoped(query, {"tag", slug}), do: Ash.Query.filter(query, exists(tags, slug == ^slug))

  defp scoped(query, {"author", slug}),
    do: Ash.Query.filter(query, exists(bloggers, slug == ^slug))

  defp item(post, site, full?) do
    case Address.of(post, site.id) do
      nil ->
        []

      path ->
        [
          %{
            url: Helpers.site_url(site.host, path),
            title: post.title,
            summary: summary(post),
            content_html: if(full?, do: post.rendered_content),
            published_at: post.published_at,
            updated_at: post.updated_at || post.published_at,
            authors: Enum.map(post.bloggers, & &1.display_name),
            categories: Enum.map(post.collections, & &1.name),
            image_url: absolute(site, post.featured_image_url),
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

  defp absolute(_site, "//" <> _), do: nil
  defp absolute(site, "/" <> _ = path), do: Helpers.site_url(site.host, path)
  defp absolute(_site, "http://" <> _ = url), do: url
  defp absolute(_site, "https://" <> _ = url), do: url
  defp absolute(_site, _other), do: nil

  defp documents(site, scope, language, {name, link}, items) do
    site_title = Settings.get("site.title", "Mishka CMS", site.id)
    title = if is_binary(name) and name != "", do: site_title <> " - " <> name, else: site_title

    updated_at =
      items |> Enum.map(& &1.updated_at) |> Enum.max(DateTime, fn -> DateTime.utc_now() end)

    for format <- Renderer.formats(), into: %{} do
      body =
        Renderer.render(format, %{
          title: title,
          description: title,
          language: language,
          link: Helpers.site_url(site.host, link || "/"),
          self_url: Helpers.site_url(site.host, Feeds.path(scope, format, language, site.id)),
          updated_at: updated_at,
          items: items
        })

      {format,
       %{
         body: body,
         etag: etag(body),
         last_modified: Calendar.strftime(updated_at, "%a, %d %b %Y %H:%M:%S GMT"),
         content_type: Renderer.content_type(format)
       }}
    end
  end

  defp etag(body) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    ~s(W/"#{hash}")
  end

  defp keep(site_id, type, documents) do
    AssetsState.save(%{
      id: site_id,
      type: type,
      value: documents,
      hash: nil,
      updated_at: DateTime.utc_now()
    })
  end
end
