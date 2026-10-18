# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.SitemapUrlsTest do
  @moduledoc """
  What the blog adds to a site's sitemap: every post, category, blogger and team a visitor can open at
  an address a search engine may index, and the tags that ask for it, at the address the blog's own
  page answers it on, and nothing else.

  A row is listed exactly when the head of its page lets a search engine index it — the last
  describe holds each kind's listing to the robots meta `MishkaBlog.Plugins.PageSeo` and core's head
  write for it. Core hands the plugin the site's indexable pages
  (`MishkaCmsCore.Runtime.PageEditions.indexable/1`); these tests hand it the same read, so a page
  switched off here is missing from it exactly as it is from core's. Every status the generators
  could pick is pinned. What it returns is a stream, as core reads it, so each test reads it to the
  end.
  """
  use MishkaBlog.DataCase,
    async: false,
    parameterize: for(mode <- ~w(prefix_others prefix_all), do: %{mode: mode})

  alias MishkaBlog.Plugins.{PageSeo, SitemapUrls}
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  setup %{mode: mode} do
    site = create_site!(active: true)
    in_mode!(site, mode)

    {:ok, site: site}
  end

  # English and Persian on `site`, its addresses named in `mode`.
  defp in_mode!(site, mode) do
    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)
  end

  # Where English, the site's first language, puts `path` in `mode`: under no prefix while the first
  # language goes without one, under its own once every language carries one.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  # The blog's page reading one `kind` of row, answering every language, saying the kind it shows, as
  # the provision writes it.
  defp item_page!(site, kind, overrides \\ []) do
    {extra, overrides} = Keyword.pop(overrides, :extra, %{"serves_all_languages" => true})

    [
      site_id: site.id,
      path: Provision.item_paths()[kind],
      extra: Map.put(extra, "record", "blog:#{kind}"),
      active: true,
      permissions: []
    ]
    |> Keyword.merge(overrides)
    |> create_page!()
  end

  defp post!(site, status, overrides \\ []) do
    create_blog_post!([site_id: site.id, status: status, language: "en"] ++ overrides)
  end

  # The addresses so far as core hands them over, a stream.
  defp payload(site, urls \\ []) do
    {pages, _hidden} = PageEditions.indexable(site.id)
    %{site: site, pages: pages, urls: Stream.map(urls, & &1)}
  end

  defp urls(site, existing \\ []) do
    {:reply, %{urls: urls}} = SitemapUrls.call(payload(site, existing))
    Enum.to_list(urls)
  end

  defp paths(site), do: site |> urls() |> Enum.map(& &1.path) |> Enum.sort()

  defp robots(content), do: [%{tag: "meta", attrs: %{"name" => "robots"}, content: content}]

  # A page at a path of the site's own choosing, with no language in it, saying the kind it shows.
  defp record_page!(site, path, record) do
    create_page!(
      site_id: site.id,
      path: path,
      extra: %{"record" => record},
      active: true,
      permissions: []
    )
  end

  describe "a blog at the site's root" do
    test "is found by the kind each page shows, not by the provision's path", %{site: site} do
      record_page!(site, "/blog/:slug", "blog:post")
      record_page!(site, "/blog/category/:slug", "blog:category")
      post = post!(site, :published)
      category = create_collection!(site_id: site.id, status: :active, language: "en")
      create_post_collection!(post_id: post.id, collection_id: category.id)

      assert paths(site) == Enum.sort(["/blog/#{post.slug}", "/blog/category/#{category.slug}"])
    end
  end

  describe "bloggers and teams" do
    test "every blogger who is not archived and every active team is listed, with posts or without",
         %{site: site} do
      record_page!(site, "/blog/author/:slug", "blog:author")
      record_page!(site, "/blog/team/:slug", "blog:team")

      writer = create_blogger!(site_id: site.id, slug: "shahryar")
      silent = create_blogger!(site_id: site.id, slug: "silent")
      archived = create_blogger!(site_id: site.id, slug: "archived")
      team = create_team!(site_id: site.id, slug: "core", status: :active)
      empty = create_team!(site_id: site.id, slug: "empty", status: :active)
      create_team!(site_id: site.id, slug: "idle", status: :inactive)
      create_team!(site_id: site.id, slug: "planned", status: :draft)
      create_team_member!(team_id: team.id, blogger_id: writer.id)

      post = post!(site, :published)
      create_post_blogger!(post_id: post.id, blogger_id: writer.id)

      archived
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      assert site |> urls() |> Map.new(&{&1.path, &1.lastmod}) == %{
               "/blog/author/shahryar" => writer.updated_at,
               "/blog/author/silent" => silent.updated_at,
               "/blog/team/core" => team.updated_at,
               "/blog/team/empty" => empty.updated_at
             }
    end

    test "a blogger with no post at all is listed", %{site: site} do
      record_page!(site, "/blog/author/:slug", "blog:author")
      create_blogger!(site_id: site.id, slug: "arian-alijani")

      assert paths(site) == ["/blog/author/arian-alijani"]
    end

    test "each is listed in every language its page answers", %{site: site, mode: mode} do
      item_page!(site, :author)
      item_page!(site, :team)
      create_blogger!(site_id: site.id, slug: "shahryar")
      create_team!(site_id: site.id, slug: "core", status: :active)

      assert paths(site) ==
               Enum.sort([
                 english(mode, "/blog/author/shahryar"),
                 "/fa/blog/author/shahryar",
                 english(mode, "/blog/team/core"),
                 "/fa/blog/team/core"
               ])
    end

    test "nothing is listed without their pages", %{site: site} do
      writer = create_blogger!(site_id: site.id)
      create_team!(site_id: site.id, status: :active)
      post = post!(site, :published)
      create_post_blogger!(post_id: post.id, blogger_id: writer.id)

      assert paths(site) == []
    end

    test "none is listed while their page is noindex or closed to visitors", %{site: site} do
      item_page!(site, :author, seo_tags: robots("noindex, follow"))
      item_page!(site, :team, permissions: ["members:read"])
      create_blogger!(site_id: site.id)
      create_team!(site_id: site.id, status: :active)

      assert paths(site) == []
    end
  end

  describe "posts" do
    test "a published post is listed in its own language, after what the payload held", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      persian = post!(site, :published, language: "fa")
      english = post!(site, :published)
      core = %{path: "/about", lastmod: nil}

      assert [^core | added] = urls(site, [core])

      assert Enum.sort_by(added, & &1.path) ==
               Enum.sort_by(
                 [
                   %{
                     path: english(mode, "/blog/#{english.slug}"),
                     lastmod: english.updated_at,
                     images: []
                   },
                   %{path: "/fa/blog/#{persian.slug}", lastmod: persian.updated_at, images: []}
                 ],
                 & &1.path
               )
    end

    test "each carries its featured image, a path or an address as it is stored", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      hosted = post!(site, :published, featured_image_url: "https://cdn.example.com/cover.png")
      local = post!(site, :published, featured_image_url: "/media/cover.png")
      bare = post!(site, :published)

      assert site |> urls() |> Map.new(&{&1.path, &1.images}) == %{
               english(mode, "/blog/#{hosted.slug}") => ["https://cdn.example.com/cover.png"],
               english(mode, "/blog/#{local.slug}") => ["/media/cover.png"],
               english(mode, "/blog/#{bare.slug}") => []
             }
    end

    test "a draft, a scheduled, an archived post and one in a language the site lacks are not", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      published = post!(site, :published)

      post!(site, :draft)
      post!(site, :published, language: "de")

      post!(site, :scheduled,
        scheduled_publish_at:
          DateTime.utc_now() |> DateTime.add(3700) |> DateTime.truncate(:second)
      )

      site
      |> post!(:published)
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      assert paths(site) == [english(mode, "/blog/#{published.slug}")]
    end

    test "one that names a permission, or whose own robots meta says noindex or none, is not", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      listed = post!(site, :published, seo_tags: robots("index, follow"))

      post!(site, :published, permissions: ["members:read"])
      post!(site, :published, seo_tags: robots("noindex, follow"))
      post!(site, :published, seo_tags: robots("none"))

      assert paths(site) == [english(mode, "/blog/#{listed.slug}")]
    end

    test "one filed under a locked category, or a category under one, is not", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      item_page!(site, :category)

      members =
        create_collection!(
          site_id: site.id,
          status: :active,
          language: "en",
          permissions: ["members:read"]
        )

      guides =
        create_collection!(
          site_id: site.id,
          status: :active,
          language: "en",
          parent_collection_id: members.id
        )

      open = create_collection!(site_id: site.id, status: :active, language: "en")

      [listed | _locked] =
        for category <- [open, members, guides] do
          post = post!(site, :published)
          create_post_collection!(post_id: post.id, collection_id: category.id)
          post
        end

      assert paths(site) ==
               Enum.sort([
                 english(mode, "/blog/#{listed.slug}"),
                 english(mode, "/blog/category/#{open.slug}")
               ])
    end

    test "a post page written in one language lists that language's posts alone", %{site: site} do
      item_page!(site, :post, extra: %{}, language: "fa")
      persian = post!(site, :published, language: "fa")
      post!(site, :published)

      assert paths(site) == ["/fa/blog/#{persian.slug}"]
    end

    test "none is listed while no page answers the post path", %{site: site} do
      item_page!(site, :post, active: false)
      create_page!(site_id: site.id, path: "/:lang/articles/:slug", active: true, permissions: [])
      post!(site, :published)

      assert urls(site) == []
    end

    # EACH READ STARTS AFTER THE LAST ROW THE ONE BEFORE IT RETURNED, never at an offset that walks
    # every row before it again. Beside each one is the read of the site's locked posts that keeps
    # it to what a guest may open, which reads no rows of the page.
    test "every one is listed, a hundred read at a time after the last one read", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :post)
      slugs = for _ <- 1..101, do: post!(site, :published).slug
      parent = self()

      asked = queries_while(fn -> send(parent, {:paths, paths(site)}) end)

      assert_received {:paths, listed}
      assert listed == slugs |> Enum.map(&english(mode, "/blog/#{&1}")) |> Enum.sort()

      assert [first, second] =
               asked
               |> Enum.reverse()
               |> Enum.filter(&(&1 =~ ~s("mishka_blog_posts") and &1 =~ ~s(ORDER BY m0."id")))

      refute first =~ ~s("id"::uuid >)
      assert second =~ ~s("id"::uuid >)
      refute Enum.any?([first, second], &(&1 =~ "OFFSET"))
    end
  end

  describe "categories and tags" do
    test "an active category is listed with its updated_at, with a published post or without", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :category)
      item_page!(site, :tag)

      english = post!(site, :published)
      persian = post!(site, :published, language: "fa")

      filled = create_collection!(site_id: site.id, status: :active, language: "en")
      create_post_collection!(post_id: english.id, collection_id: filled.id)
      empty = create_collection!(site_id: site.id, status: :active, language: "fa")

      tag = create_blog_tag!(site_id: site.id, language: "fa")
      create_post_tag!(post_id: persian.id, tag_id: tag.id)

      assert site |> urls() |> Map.new(&{&1.path, &1.lastmod}) == %{
               english(mode, "/blog/category/#{filled.slug}") => filled.updated_at,
               "/fa/blog/category/#{empty.slug}" => empty.updated_at
             }
    end

    test "one that names a permission, or whose own robots meta says noindex or none, is not", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :category)

      [category | _hidden] =
        for overrides <- [
              [],
              [permissions: ["members:read"]],
              [seo_tags: robots("noindex")],
              [seo_tags: robots("none")]
            ] do
          create_collection!([site_id: site.id, status: :active, language: "en"] ++ overrides)
        end

      assert paths(site) == [english(mode, "/blog/category/#{category.slug}")]
    end

    # A CATEGORY'S POSTS DO NOT DECIDE IT. Its page opens on "nothing is published" for a guest when
    # the posts filed under it are locked, in another language or drafts, and the head still says
    # `index`, so it is listed.
    test "one whose posts are locked, in another language or drafts is listed all the same", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :category)

      posts = [
        post!(site, :published, permissions: ["members:read"]),
        post!(site, :published, language: "fa"),
        post!(site, :draft)
      ]

      categories =
        for post <- posts do
          category = create_collection!(site_id: site.id, status: :active, language: "en")
          create_post_collection!(post_id: post.id, collection_id: category.id)
          category
        end

      assert paths(site) ==
               categories
               |> Enum.map(&english(mode, "/blog/category/#{&1.slug}"))
               |> Enum.sort()
    end

    test "a draft or inactive category and one in a language the site lacks are not", %{
      site: site,
      mode: mode
    } do
      item_page!(site, :category)

      open = create_collection!(site_id: site.id, status: :active, language: "en")
      create_collection!(site_id: site.id, status: :draft, language: "en")
      create_collection!(site_id: site.id, status: :archived, language: "en")
      create_collection!(site_id: site.id, status: :active, language: "de")

      assert paths(site) == [english(mode, "/blog/category/#{open.slug}")]
    end

    test "a tag is not listed: its page says noindex", %{site: site} do
      item_page!(site, :tag)

      post = post!(site, :published)
      plain = create_blog_tag!(site_id: site.id, language: "en")
      described = create_blog_tag!(site_id: site.id, language: "en", seo_tags: description_meta())
      create_post_tag!(post_id: post.id, tag_id: plain.id)
      create_post_tag!(post_id: post.id, tag_id: described.id)

      assert urls(site) == []
    end

    # A TAG'S OWN ROBOTS META WINS IN ITS HEAD, so a tag that says `index` is a page a search engine
    # may index, and is listed with its updated_at — unless it names a permission.
    test "a tag whose own robots meta says index is listed; noindex, none and locked ones are not",
         %{site: site, mode: mode} do
      item_page!(site, :tag)

      indexed =
        create_blog_tag!(site_id: site.id, language: "en", seo_tags: robots("index, follow"))

      following = create_blog_tag!(site_id: site.id, language: "fa", seo_tags: robots("follow"))

      for overrides <- [
            [seo_tags: robots("noindex, follow")],
            [seo_tags: robots("none")],
            [seo_tags: robots("index, follow"), permissions: ["members:read"]],
            [seo_tags: robots("index, follow"), language: "de"]
          ] do
        create_blog_tag!([site_id: site.id, language: "en"] ++ overrides)
      end

      assert site |> urls() |> Map.new(&{&1.path, &1.lastmod}) == %{
               english(mode, "/blog/tag/#{indexed.slug}") => indexed.updated_at,
               "/fa/blog/tag/#{following.slug}" => following.updated_at
             }
    end
  end

  # EACH KIND'S LISTING IS HELD TO THE HEAD ITS PAGE WRITES. A row is listed exactly when the robots
  # meta `MishkaBlog.Plugins.PageSeo` and core's head give its page lets a search engine index it and
  # it opens with no permission — a locked page is one a crawler is sent away from, whatever it says.
  describe "what is listed is what the head lets a search engine index" do
    @host "blog.example.com"

    defp base, do: Seo.base(@host)

    defp description_meta,
      do: [%{tag: "meta", attrs: %{"name" => "description"}, content: "A description"}]

    # The head core builds for the page at `path` showing the row `slug` names, as
    # `MishkaCmsWeb.RuntimeLive` builds it: whether its robots meta says index, and what it opens with.
    defp head_of(site, path, record, slug) do
      params = %{"slug" => slug}

      given =
        Seo.given(
          %{title: "Blog", path: path, language: "en", seo: %{description: nil, schema: []}},
          site_id: site.id,
          url: base() <> Languages.url(path, params, site.id),
          params: params,
          record: record
        )

      {:reply, :halt, answered} = PageSeo.call(given)
      head = answered |> Seo.accept(given) |> Seo.head(base: base())

      directives =
        for {"meta", attrs} <- head.tags,
            {"name", "robots"} in attrs,
            {"content", content} <- attrs,
            directive <- String.split(content, [",", " "], trim: true),
            do: directive

      %{
        indexed?: directives != [] and directives -- ["noindex", "none"] == directives,
        head: head
      }
    end

    defp says_index?(site, path, record, slug) do
      %{indexed?: indexed?, head: head} = head_of(site, path, record, slug)
      indexed? and head.permissions == []
    end

    # Every row of `rows` against the sitemap: listed when and only when its page says index, and at
    # least one of each in the set so that neither side is vacuous.
    defp assert_listed_as_indexed(site, path, record, rows) do
      listed = MapSet.new(paths(site))

      verdicts =
        for row <- rows do
          address = String.replace(path, ":slug", row.slug)
          says = says_index?(site, path, record, row.slug)

          assert MapSet.member?(listed, address) == says,
                 "#{record} #{row.slug} is #{if says, do: "indexable", else: "not indexable"} but " <>
                   "#{if MapSet.member?(listed, address), do: "listed", else: "not listed"}"

          says
        end

      assert true in verdicts and false in verdicts
    end

    test "posts", %{site: site} do
      record_page!(site, "/blog/:slug", "blog:post")

      rows =
        for overrides <- [
              [],
              [seo_tags: robots("index, follow")],
              [seo_tags: robots("noindex, follow")],
              [seo_tags: robots("none")],
              [permissions: ["members:read"]],
              [seo_tags: robots("index"), permissions: ["members:read"]]
            ],
            do: post!(site, :published, overrides)

      assert_listed_as_indexed(site, "/blog/:slug", "blog:post", rows)
    end

    test "categories, with posts and without", %{site: site} do
      record_page!(site, "/blog/category/:slug", "blog:category")

      rows =
        for overrides <- [
              [],
              [seo_tags: robots("index, follow")],
              [seo_tags: robots("noindex, follow")],
              [seo_tags: robots("none")],
              [permissions: ["members:read"]]
            ] do
          create_collection!([site_id: site.id, status: :active, language: "en"] ++ overrides)
        end

      filed = post!(site, :published)
      create_post_collection!(post_id: filed.id, collection_id: hd(rows).id)

      assert_listed_as_indexed(site, "/blog/category/:slug", "blog:category", rows)
    end

    test "tags, whatever they hold", %{site: site} do
      record_page!(site, "/blog/tag/:slug", "blog:tag")

      rows =
        for overrides <- [
              [],
              [seo_tags: description_meta()],
              [seo_tags: robots("index, follow")],
              [seo_tags: robots("noindex, follow")],
              [seo_tags: robots("none")],
              [permissions: ["members:read"]],
              [seo_tags: robots("index, follow"), permissions: ["members:read"]]
            ] do
          create_blog_tag!([site_id: site.id, language: "en"] ++ overrides)
        end

      assert_listed_as_indexed(site, "/blog/tag/:slug", "blog:tag", rows)
    end

    test "bloggers, with posts and without", %{site: site} do
      record_page!(site, "/blog/author/:slug", "blog:author")

      writer = create_blogger!(site_id: site.id)
      silent = create_blogger!(site_id: site.id)
      create_post_blogger!(post_id: post!(site, :published).id, blogger_id: writer.id)

      listed = MapSet.new(paths(site))

      for blogger <- [writer, silent] do
        assert says_index?(site, "/blog/author/:slug", "blog:author", blogger.slug)
        assert MapSet.member?(listed, "/blog/author/#{blogger.slug}")
      end
    end

    test "teams, with members and without", %{site: site} do
      record_page!(site, "/blog/team/:slug", "blog:team")

      crew = create_team!(site_id: site.id, status: :active)
      empty = create_team!(site_id: site.id, status: :active)
      create_team_member!(team_id: crew.id, blogger_id: create_blogger!(site_id: site.id).id)

      listed = MapSet.new(paths(site))

      for team <- [crew, empty] do
        assert says_index?(site, "/blog/team/:slug", "blog:team", team.slug)
        assert MapSet.member?(listed, "/blog/team/#{team.slug}")
      end
    end
  end

  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert SitemapUrls in MishkaBlog.Application.plugins()
    end

    # CORE READS THE STREAM ONCE THE WHOLE CHAIN HAS RUN, in the site's sitemap job, so a row written
    # between the two is in it.
    test "reads nothing while it is called, and every row once its stream is read", %{
      site: site,
      mode: mode
    } do
      for kind <- [:post, :category, :tag], do: item_page!(site, kind)
      data = payload(site)
      parent = self()

      assert queries_while(fn -> send(parent, SitemapUrls.call(data)) end) == []
      assert_received {:reply, %{urls: urls}}

      post = post!(site, :published)

      assert Enum.map(urls, & &1.path) == [english(mode, "/blog/#{post.slug}")]
    end

    test "hands back a payload whose addresses are not enumerable as it came", %{site: site} do
      item_page!(site, :post)
      post!(site, :published)
      data = %{payload(site) | urls: nil}

      assert SitemapUrls.call(data) == {:reply, data}
    end

    # Registered by hand for the reason `MishkaBlog.ProvisionTest`'s `listening!/0` gives: this
    # suite's registry is not up when the extension's supervisor starts its plugins.
    test "answers `seo:sitemap:urls`, the event core fires", %{site: site, mode: mode} do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile(SitemapUrls.config(:__event__), :start, false)

      item_page!(site, :post)
      post = post!(site, :published)

      assert %{urls: urls} = Hook.call("seo:sitemap:urls", payload(site))
      assert [%{path: path}] = Enum.to_list(urls)
      assert path == english(mode, "/blog/#{post.slug}")
    end

    # THE CONTRACT AS CORE READS IT: the build of the site's sitemap reads the stream this returns,
    # writes each address on the site's own address with its date to the second, and makes a post's
    # image absolute there. A site of its own, cached as the build finds it: the generator's names
    # start over in every test, and the cache outlives the rollback.
    test "is read by the build of the site's sitemap, on the site's own address", %{mode: mode} do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile(SitemapUrls.config(:__event__), :start, false)

      name = "sitemapblog#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)
      in_mode!(site, mode)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: true,
          master: site.master
        })

      on_exit(fn ->
        SiteState.delete(site.id)
        AssetsState.delete(site.name, "sitemap")
      end)

      item_page!(site, :post)
      post = post!(site, :published, featured_image_url: "/media/cover.png")

      assert {:ok, %{files: %{"sitemap-00001.xml.gz" => gz}}} =
               SitemapCompiler.compile_and_store(site.name)

      origin = Helpers.site_url(site.host, "")
      lastmod = post.updated_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      file = :zlib.gunzip(gz)

      assert Regex.scan(~r{<loc>([^<]*)</loc>}, file, capture: :all_but_first) == [
               [origin <> english(mode, "/blog/#{post.slug}")]
             ]

      assert file =~ "<lastmod>#{lastmod}</lastmod>"
      assert file =~ "<image:loc>#{origin}/media/cover.png</image:loc>"
    end
  end
end
