defmodule MishkaBlog.Plugins.SitemapUrls do
  @moduledoc """
  Adds the blog's posts, categories, bloggers and teams to a site's `/sitemap.xml`, through
  the
  `seo:sitemap:urls` mishka_installer hook `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` fires
  when it builds a site's sitemap. A post, category or tag written rebuilds its site's sitemap,
  because those resources list `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`.

  Core lists the blog's pages whose only capture is the language. `/:lang/blog/:slug` also holds a
  slug only this extension can fill, so core hands such a page over in the payload's `pages`, and
  this fills it:

    * a published post, at the post page, with `lastmod` its `updated_at` and `images` its
      `featured_image_url`, or none when it has no such image;
    * a category holding a published post in its own language, at its page, with no `lastmod`;
    * a blogger with a published post, and a team one of whose members has one, at its page in
      each language the page answers, with no `lastmod`.

  A tag is never listed: its page says `noindex` (`MishkaBlog.Plugins.PageSeo`).

  Each row at its own language and slug, at the address the site's URL mode gives it
  (`MishkaCmsCore.Runtime.Languages.url/3`). A kind is listed only while `pages` holds its page —
  the page whose `extra` says it shows that kind (`"blog:post"`, `"blog:category"`,
  `"blog:author"`, `"blog:team"`), which every page `MishkaBlog.Provision` writes says — so a page
  switched off, closed to visitors or marked noindex lists nothing — and a row only in a
  language that page answers (`PageEditions.served_languages/2`), so no address here 404s. A row
  that opens with a permission, or whose own `seo_tags` hold a robots meta saying `noindex` or
  `none`, is left out as such a page is (`PageEditions.listed?/2`): a post or a category in a locked
  category is too, as its page asks for that category's
  (`MishkaBlog.Resources.Calculations.EffectivePermissions`).

  The addresses follow the payload's `urls` as a stream, and nothing is read while the hook runs:
  the build reads the rows as it reads the stream, through `:public_list` as the blog's pages read
  them, on the payload's site, as a guest — a build has nobody signed in behind it, and a crawler is
  a guest — a hundred at a time after the last one read
  (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler.stream_rows/2`). Each row is listed once, since
  a slug is unique on its site. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{BlogPost, Blogger, Collection, Team}
  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler

  # Each kind of row: the record its page says it shows, the fields its address and whether it is
  # listed are read from, and what it loads to know the permissions it opens with.
  @kinds [
    {"blog:post", BlogPost,
     [:slug, :language, :updated_at, :featured_image_url, :permissions, :seo_tags],
     [:effective_permissions]},
    {"blog:category", Collection, [:slug, :language, :permissions, :seo_tags],
     [:effective_permissions]}
  ]

  # A blogger or a team is one row in every language, and opens with no permission of its own.
  @people [{"blog:author", Blogger}, {"blog:team", Team}]

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
    records =
      Stream.flat_map(@kinds, fn {record, resource, fields, loads} ->
        case page_for(pages, record) do
          nil ->
            []

          page ->
            resource
            |> rows(fields, loads, PageEditions.served_languages(page, site_id), site_id)
            |> Stream.filter(&PageEditions.listed?(%{&1 | permissions: opens_with(&1)}))
            |> Stream.map(&entry(page, &1, site_id))
        end
      end)

    people =
      Stream.flat_map(@people, fn {record, resource} ->
        case page_for(pages, record) do
          nil -> []
          page -> people_entries(page, resource, site_id)
        end
      end)

    Stream.concat(records, people)
  end

  # The page that says it shows `record`.
  defp page_for(pages, record), do: Enum.find(pages, &(Seo.record_of(&1.extra) == record))

  defp people_entries(page, resource, site_id) do
    languages = PageEditions.served_languages(page, site_id)

    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> with_published_post(resource)
    |> Ash.Query.select([:slug])
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
    |> Stream.flat_map(fn row ->
      languages
      |> Enum.map(&address(page, &1, row.slug, site_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&%{path: &1, lastmod: nil})
    end)
  end

  defp with_published_post(query, Blogger),
    do: Ash.Query.filter(query, exists(tenant_posts, status == :published))

  defp with_published_post(query, Team),
    do:
      Ash.Query.filter(
        query,
        exists(tenant_members, exists(tenant_posts, status == :published))
      )

  defp rows(_resource, _fields, _loads, [], _site_id), do: []

  defp rows(resource, fields, loads, languages, site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language in ^languages)
    |> published(resource)
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
  end

  defp opens_with(%{effective_permissions: permissions}) when is_list(permissions),
    do: permissions

  defp opens_with(row), do: row.permissions

  # `:public_list` already holds a post to the published ones; a category is listed while a published
  # post in its own language is filed under it — its page lists that language's alone, so
  # `published_post_count`, which counts every language, would list a page that opens empty.
  defp published(query, BlogPost), do: query

  defp published(query, _term) do
    Ash.Query.filter(
      query,
      exists(tenant_posts, status == :published and language == parent(language))
    )
  end

  defp entry(page, %BlogPost{} = post, site_id) do
    %{
      path: address(page, post.language, post.slug, site_id),
      lastmod: post.updated_at,
      images: List.wrap(post.featured_image_url)
    }
  end

  defp entry(page, row, site_id),
    do: %{path: address(page, row.language, row.slug, site_id), lastmod: nil}

  defp address(page, language, slug, site_id),
    do: Languages.url(page.path, %{Languages.capture() => language, "slug" => slug}, site_id)
end
