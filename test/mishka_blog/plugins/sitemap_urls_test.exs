defmodule MishkaBlog.Plugins.SitemapUrlsTest do
  @moduledoc """
  What the blog adds to a site's sitemap: every post, category and tag a visitor can open, at the
  address the blog's own page answers it on, and nothing else.

  Core hands the plugin the site's indexable pages (`MishkaCmsCore.Runtime.PageEditions.indexable/1`);
  these tests hand it the same read, so a page switched off here is missing from it exactly as it is
  from core's. Every status the generators could pick is pinned. What it returns is a stream, as
  core reads it, so each test reads it to the end.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Plugins.SitemapUrls
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.PageEditions
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  setup do
    site = create_site!(active: true)

    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    {:ok, site: site}
  end

  # The blog's page reading one `kind` of row, answering every language, as the provision writes it.
  defp item_page!(site, kind, overrides \\ []) do
    [
      site_id: site.id,
      path: Provision.item_paths()[kind],
      extra: %{"serves_all_languages" => true},
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

  # A page at a path of the site's own choosing, saying the kind it shows, answering every language.
  defp record_page!(site, path, record) do
    create_page!(
      site_id: site.id,
      path: path,
      extra: %{"serves_all_languages" => true, "record" => record},
      active: true,
      permissions: []
    )
  end

  describe "a blog at the site's root" do
    test "is found by the kind each page shows, not by the provision's path", %{site: site} do
      record_page!(site, "/blog/:slug", "blog:post")
      record_page!(site, "/blog/tag/:slug", "blog:tag")
      post = post!(site, :published)
      tag = create_blog_tag!(site_id: site.id, name: "elixir", language: "en")
      create_post_tag!(post_id: post.id, tag_id: tag.id)

      assert paths(site) == Enum.sort(["/blog/#{post.slug}", "/blog/tag/#{tag.slug}"])
    end
  end

  describe "bloggers and teams" do
    test "a blogger with a published post and that blogger's team are listed, once each", %{
      site: site
    } do
      record_page!(site, "/blog/author/:slug", "blog:author")
      record_page!(site, "/blog/team/:slug", "blog:team")

      writer = create_blogger!(site_id: site.id, slug: "shahryar")
      create_blogger!(site_id: site.id, slug: "silent")
      team = create_team!(site_id: site.id, slug: "core", status: :active)
      create_team!(site_id: site.id, slug: "empty", status: :active)
      create_team_member!(team_id: team.id, blogger_id: writer.id)

      post = post!(site, :published)
      create_post_blogger!(post_id: post.id, blogger_id: writer.id)

      assert paths(site) == ["/blog/author/shahryar", "/blog/team/core"]
    end

    test "nothing is listed without their pages", %{site: site} do
      writer = create_blogger!(site_id: site.id)
      post = post!(site, :published)
      create_post_blogger!(post_id: post.id, blogger_id: writer.id)

      assert paths(site) == []
    end
  end

  describe "posts" do
    test "a published post is listed in its own language, after what the payload held", %{
      site: site
    } do
      item_page!(site, :post)
      persian = post!(site, :published, language: "fa")
      english = post!(site, :published)
      core = %{path: "/about", lastmod: nil}

      assert [^core | added] = urls(site, [core])

      assert Enum.sort_by(added, & &1.path) ==
               Enum.sort_by(
                 [
                   %{path: "/en/blog/#{english.slug}", lastmod: english.updated_at, images: []},
                   %{path: "/fa/blog/#{persian.slug}", lastmod: persian.updated_at, images: []}
                 ],
                 & &1.path
               )
    end

    test "each carries its featured image, a path or an address as it is stored", %{site: site} do
      item_page!(site, :post)
      hosted = post!(site, :published, featured_image_url: "https://cdn.example.com/cover.png")
      local = post!(site, :published, featured_image_url: "/media/cover.png")
      bare = post!(site, :published)

      assert site |> urls() |> Map.new(&{&1.path, &1.images}) == %{
               "/en/blog/#{hosted.slug}" => ["https://cdn.example.com/cover.png"],
               "/en/blog/#{local.slug}" => ["/media/cover.png"],
               "/en/blog/#{bare.slug}" => []
             }
    end

    test "a draft, a scheduled, an archived post and one in a language the site lacks are not", %{
      site: site
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

      assert paths(site) == ["/en/blog/#{published.slug}"]
    end

    test "one that names a permission, or whose own robots meta says noindex or none, is not", %{
      site: site
    } do
      item_page!(site, :post)
      listed = post!(site, :published, seo_tags: robots("index, follow"))

      post!(site, :published, permissions: ["members:read"])
      post!(site, :published, seo_tags: robots("noindex, follow"))
      post!(site, :published, seo_tags: robots("none"))

      assert paths(site) == ["/en/blog/#{listed.slug}"]
    end

    test "one filed under a locked category, or a category under one, is not", %{site: site} do
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
               Enum.sort(["/en/blog/#{listed.slug}", "/en/blog/category/#{open.slug}"])
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
    # every row before it again.
    test "every one is listed, a hundred read at a time after the last one read", %{site: site} do
      item_page!(site, :post)
      slugs = for _ <- 1..101, do: post!(site, :published).slug
      parent = self()

      asked = queries_while(fn -> send(parent, {:paths, paths(site)}) end)

      assert_received {:paths, listed}
      assert listed == slugs |> Enum.map(&"/en/blog/#{&1}") |> Enum.sort()

      assert [first, second] =
               asked |> Enum.reverse() |> Enum.filter(&(&1 =~ ~s("mishka_blog_posts")))

      refute first =~ ~s("id"::uuid >)
      assert second =~ ~s("id"::uuid >)
      refute Enum.any?([first, second], &(&1 =~ "OFFSET"))
    end
  end

  describe "categories and tags" do
    test "each holding a published post is listed, with no lastmod", %{site: site} do
      item_page!(site, :category)
      item_page!(site, :tag)

      english = post!(site, :published)
      persian = post!(site, :published, language: "fa")

      category = create_collection!(site_id: site.id, status: :active, language: "en")
      create_post_collection!(post_id: english.id, collection_id: category.id)

      tag = create_blog_tag!(site_id: site.id, language: "fa")
      create_post_tag!(post_id: persian.id, tag_id: tag.id)

      assert Enum.sort_by(urls(site), & &1.path) == [
               %{path: "/en/blog/category/#{category.slug}", lastmod: nil},
               %{path: "/fa/blog/tag/#{tag.slug}", lastmod: nil}
             ]
    end

    test "one that names a permission, or whose own robots meta says noindex or none, is not", %{
      site: site
    } do
      item_page!(site, :category)
      item_page!(site, :tag)

      post = post!(site, :published)

      [category | _hidden] =
        for overrides <- [[], [permissions: ["members:read"]], [seo_tags: robots("noindex")]] do
          category =
            create_collection!([site_id: site.id, status: :active, language: "en"] ++ overrides)

          create_post_collection!(post_id: post.id, collection_id: category.id)
          category
        end

      [tag | _hidden] =
        for overrides <- [[], [permissions: ["members:read"]], [seo_tags: robots("none")]] do
          tag = create_blog_tag!([site_id: site.id, language: "en"] ++ overrides)
          create_post_tag!(post_id: post.id, tag_id: tag.id)
          tag
        end

      assert paths(site) == [
               "/en/blog/category/#{category.slug}",
               "/en/blog/tag/#{tag.slug}"
             ]
    end

    # ITS PAGE LISTS ITS OWN LANGUAGE'S POSTS ALONE, so one whose published posts are all in another
    # language opens on "nothing is published" — the rule the blog kit's `with_public_post` keeps.
    test "one whose only published post is in another language is not", %{site: site} do
      item_page!(site, :category)
      item_page!(site, :tag)

      persian = post!(site, :published, language: "fa")

      category = create_collection!(site_id: site.id, status: :active, language: "en")
      create_post_collection!(post_id: persian.id, collection_id: category.id)

      tag = create_blog_tag!(site_id: site.id, language: "en")
      create_post_tag!(post_id: persian.id, tag_id: tag.id)

      assert urls(site) == []
    end

    test "an empty one, one holding only a draft, a draft category and an unlisted language are not",
         %{site: site} do
      item_page!(site, :category)
      item_page!(site, :tag)

      published = post!(site, :published)
      draft = post!(site, :draft)

      create_collection!(site_id: site.id, status: :active, language: "en")
      create_blog_tag!(site_id: site.id, language: "en")

      for {status, language, post} <- [
            {:active, "en", draft},
            {:draft, "en", published},
            {:active, "de", published}
          ] do
        category = create_collection!(site_id: site.id, status: status, language: language)
        create_post_collection!(post_id: post.id, collection_id: category.id)
      end

      for {language, post} <- [{"en", draft}, {"de", published}] do
        tag = create_blog_tag!(site_id: site.id, language: language)
        create_post_tag!(post_id: post.id, tag_id: tag.id)
      end

      assert urls(site) == []
    end
  end

  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert SitemapUrls in MishkaBlog.Application.plugins()
    end

    # CORE READS THE STREAM ONCE THE WHOLE CHAIN HAS RUN, in the site's sitemap job, so a row written
    # between the two is in it.
    test "reads nothing while it is called, and every row once its stream is read", %{site: site} do
      for kind <- [:post, :category, :tag], do: item_page!(site, kind)
      data = payload(site)
      parent = self()

      assert queries_while(fn -> send(parent, SitemapUrls.call(data)) end) == []
      assert_received {:reply, %{urls: urls}}

      post = post!(site, :published)

      assert Enum.map(urls, & &1.path) == ["/en/blog/#{post.slug}"]
    end

    test "hands back a payload whose addresses are not enumerable as it came", %{site: site} do
      item_page!(site, :post)
      post!(site, :published)
      data = %{payload(site) | urls: nil}

      assert SitemapUrls.call(data) == {:reply, data}
    end

    # Registered by hand for the reason `MishkaBlog.ProvisionTest`'s `listening!/0` gives: this
    # suite's registry is not up when the extension's supervisor starts its plugins.
    test "answers `seo:sitemap:urls`, the event core fires", %{site: site} do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile(SitemapUrls.config(:__event__), :start, false)

      item_page!(site, :post)
      post = post!(site, :published)

      assert %{urls: urls} = Hook.call("seo:sitemap:urls", payload(site))
      assert [%{path: path}] = Enum.to_list(urls)
      assert path == "/en/blog/#{post.slug}"
    end

    # THE CONTRACT AS CORE READS IT: the build of the site's sitemap reads the stream this returns,
    # writes each address on the site's own address with its date to the second, and makes a post's
    # image absolute there. A site of its own, cached as the build finds it: the generator's names
    # start over in every test, and the cache outlives the rollback.
    test "is read by the build of the site's sitemap, on the site's own address" do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile(SitemapUrls.config(:__event__), :start, false)

      name = "sitemapblog#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

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
        SettingsState.delete(site.id, "site.languages")
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
               ["#{origin}/en/blog/#{post.slug}"]
             ]

      assert file =~ "<lastmod>#{lastmod}</lastmod>"
      assert file =~ "<image:loc>#{origin}/media/cover.png</image:loc>"
    end
  end
end
