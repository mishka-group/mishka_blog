defmodule MishkaBlog.Plugins.SitemapUrls do
  @moduledoc """
  Adds the blog's posts, categories and tags to a site's `/sitemap.xml`, through the
  `seo:sitemap:urls` mishka_installer hook `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` fires
  when it builds a site's sitemap. A post, category or tag written rebuilds its site's sitemap,
  because those resources list `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`.

  Core lists the blog's pages whose only capture is the language. `/:lang/blog/:slug` also holds a
  slug only this extension can fill, so core hands such a page over in the payload's `pages`, and
  this fills it:

    * a published post, at the post page, with `lastmod` its `updated_at` and `images` its
      `featured_image_url`, or none when it has no such image;
    * a category or a tag holding a published post in its own language, at its page, with no
      `lastmod`.

  Each row at its own language and slug (`MishkaCmsCore.Runtime.PageEditions.path/2`). A kind is
  listed only while `pages` holds the page at its `MishkaBlog.Provision.item_paths/0` path — so a
  page moved, switched off, closed to visitors or marked noindex lists nothing — and a row only in a
  language that page answers (`PageEditions.served_languages/2`), so no address here 404s. A row
  that opens with a permission, or whose own `seo_tags` hold a robots meta saying `noindex` or
  `none`, is left out as such a page is (`PageEditions.listed?/2`): a post or a category in a locked
  category is too, as its page asks for that category's
  (`MishkaBlog.Resources.Calculations.EffectivePermissions`).

  The addresses follow the payload's `urls` as a stream, and nothing is read while the hook runs:
  the build reads the rows as it reads the stream, through `:public_list` as the blog's pages read
  them, on the payload's site, as the system, a hundred at a time after the last one read
  (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler.stream_rows/2`). Each row is listed once, since
  a slug is unique on its site. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{BlogPost, Collection, Provision, Tag}
  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler

  # Each kind of row, by its `Provision.item_paths/0` key, the fields its address and whether it is
  # listed are read from, and what it loads to know the permissions it opens with.
  @kinds [
    post:
      {BlogPost, [:slug, :language, :updated_at, :featured_image_url, :permissions, :seo_tags],
       [:effective_permissions]},
    category: {Collection, [:slug, :language, :permissions, :seo_tags], [:effective_permissions]},
    tag: {Tag, [:slug, :language, :permissions, :seo_tags], []}
  ]

  @impl true
  def call(%{site: %{id: site_id}, pages: pages, urls: urls} = data)
      when is_binary(site_id) and is_list(pages) do
    if Enumerable.impl_for(urls),
      do: {:reply, %{data | urls: Stream.concat(urls, blog_urls(pages, site_id))}},
      else: {:reply, data}
  end

  def call(data), do: {:reply, data}

  # Each kind whose page `pages` holds, in the languages that page answers, as the stream is read.
  defp blog_urls(pages, site_id) do
    item_paths = Provision.item_paths()

    Stream.flat_map(@kinds, fn {kind, {resource, fields, loads}} ->
      case Enum.find(pages, &(&1.path == item_paths[kind])) do
        nil ->
          []

        page ->
          resource
          |> rows(fields, loads, PageEditions.served_languages(page, site_id), site_id)
          |> Stream.filter(&PageEditions.listed?(%{&1 | permissions: opens_with(&1)}))
          |> Stream.map(&entry(page, &1))
      end
    end)
  end

  defp rows(_resource, _fields, _loads, [], _site_id), do: []

  defp rows(resource, fields, loads, languages, site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(language in ^languages)
    |> published(resource)
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
  end

  defp opens_with(%{effective_permissions: permissions}) when is_list(permissions),
    do: permissions

  defp opens_with(row), do: row.permissions

  # `:public_list` already holds a post to the published ones; a category or a tag is listed while a
  # published post in its own language is filed under it — its page lists that language's alone, so
  # `published_post_count`, which counts every language, would list a page that opens empty.
  defp published(query, BlogPost), do: query

  defp published(query, _term) do
    Ash.Query.filter(
      query,
      exists(tenant_posts, status == :published and language == parent(language))
    )
  end

  defp entry(page, %BlogPost{} = post) do
    %{
      path: path(page, post),
      lastmod: post.updated_at,
      images: List.wrap(post.featured_image_url)
    }
  end

  defp entry(page, row), do: %{path: path(page, row), lastmod: nil}

  defp path(page, row),
    do: PageEditions.path(page.path, %{Languages.capture() => row.language, "slug" => row.slug})
end
