# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.SitemapUrls do
  @moduledoc """
  Adds the blog's posts, categories, bloggers, teams and the tags that ask to be indexed to a
  site's `/sitemap.xml`, through the
  `seo:sitemap:urls` mishka_installer hook `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` fires
  when it builds a site's sitemap. A post, a category, a tag, a blogger or a team written rebuilds its
  site's sitemap, because those resources list
  `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`.

  Core lists the blog's pages whose only capture is the language. `/:lang/blog/:slug` also holds a
  slug only this extension can fill, so core hands such a page over in the payload's `pages`, and
  this fills it. A page is listed exactly when its own head lets a search engine index it, so every
  row a visitor can open at an indexable address is listed, with or without posts:

    * a published post, at the post page, with `lastmod` its `updated_at` and `images` its
      `featured_image_url`, or none when it has no such image;
    * an active category, at its page, with `lastmod` its `updated_at`;
    * a blogger who is not archived, and an active team, at its page in each language the page
      answers, with `lastmod` its `updated_at`;
    * a tag only when its own `seo_tags` hold a robots meta that says `index`: a public tag's page
      says `noindex` (`MishkaBlog.Plugins.PageSeo`) unless its own robots meta replaces that.

  Each row at its own language and slug, at the address the site's URL mode gives it
  (`MishkaCmsCore.Runtime.Languages.url/3`). A kind is listed only while `pages` holds its page —
  the page whose `extra` says it shows that kind (`"blog:post"`, `"blog:category"`, `"blog:tag"`,
  `"blog:author"`, `"blog:team"`), which every page `MishkaBlog.Provision` writes says — so a page
  switched off, closed to visitors or marked noindex lists nothing — and a row only in a
  language that page answers (`PageEditions.served_languages/2`), so no address here 404s. A row
  that opens with a permission, or whose own `seo_tags` hold a robots meta saying `noindex` or
  `none`, is left out as such a page is (`PageEditions.listed?/2`): a post or a category in a locked
  category is too, as its page asks for that category's
  (`MishkaBlog.Resources.Calculations.EffectivePermissions`).

  A kind whose page names permissions lists nothing: the build reads as a guest, and a guest is
  shown no post, category, tag, blogger or team whose page is closed to them
  (`MishkaBlog.Resources.Preparations.OpenToActor`).

  The addresses follow the payload's `urls` as a stream, and nothing is read while the hook runs:
  the build reads the rows as it reads the stream, through `:public_list` as the blog's pages read
  them, on the payload's site, as a guest — a build has nobody signed in behind it, and a crawler is
  a guest — a hundred at a time after the last one read
  (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler.stream_rows/2`). Each row is listed once, since
  a slug is unique on its site. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}

  # Each kind of row: the record its page says it shows, the fields its address and whether it is
  # listed are read from, and what it loads to know the permissions it opens with.
  @kinds [
    {"blog:post", BlogPost,
     [:slug, :language, :updated_at, :featured_image_url, :permissions, :seo_tags],
     [:effective_permissions]},
    {"blog:category", Collection, [:slug, :language, :updated_at, :permissions, :seo_tags],
     [:effective_permissions]},
    {"blog:tag", Tag, [:slug, :language, :updated_at, :permissions, :seo_tags], []}
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
            |> Stream.filter(&indexed?/1)
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
    |> Ash.Query.select([:slug, :updated_at])
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
    |> Stream.flat_map(fn row ->
      languages
      |> Enum.map(&address(page, &1, row.slug, site_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&%{path: &1, lastmod: row.updated_at})
    end)
  end

  defp rows(_resource, _fields, _loads, [], _site_id), do: []

  defp rows(resource, fields, loads, languages, site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language in ^languages)
    |> with_robots_meta(resource)
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
  end

  # Whether the page of `row` lets a search engine index it. A post or a category does unless it
  # names a permission or its robots meta says `noindex`; a tag's page says `noindex` unless its own
  # robots meta replaces that.
  defp indexed?(%Tag{} = tag),
    do: PageEditions.listed?(tag) and PageEditions.robots(tag.seo_tags) == :index

  defp indexed?(row), do: PageEditions.listed?(%{row | permissions: opens_with(row)})

  defp opens_with(%{effective_permissions: permissions}) when is_list(permissions),
    do: permissions

  defp opens_with(row), do: row.permissions

  # A tag whose `seo_tags` are empty holds no robots meta to ask to be indexed by, so only the ones
  # with some are read.
  defp with_robots_meta(query, Tag),
    do: Ash.Query.filter(query, fragment("cardinality(?) > 0", seo_tags))

  defp with_robots_meta(query, _resource), do: query

  defp entry(page, %BlogPost{} = post, site_id) do
    %{
      path: address(page, post.language, post.slug, site_id),
      lastmod: post.updated_at,
      images: List.wrap(post.featured_image_url)
    }
  end

  defp entry(page, row, site_id),
    do: %{path: address(page, row.language, row.slug, site_id), lastmod: row.updated_at}

  defp address(page, language, slug, site_id),
    do: Languages.url(page.path, %{Languages.capture() => language, "slug" => slug}, site_id)
end
