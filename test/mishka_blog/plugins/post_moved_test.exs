# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostMovedTest do
  @moduledoc """
  `MishkaBlog.Plugins.PostMoved` on `runtime:page:moved`: a post asked for under a category it is
  not filed in, or at the slug page of a site whose post page names its category, is sent to its own
  address with a 301; another of its categories, a slug nobody has and a post filed under nothing
  stay with the page. Served through core's `MishkaCmsCore.Runtime.Redirects.lookup/3`, as a live
  navigation and the plug ask it.

  `async: false`: the routing table, the site table, the settings cache and the installer's plugins
  are process-global.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Plugins.{PageRecords, PostMoved}
  alias MishkaCmsCore.PluginRegistrations
  alias MishkaCmsCore.Runtime.{Redirects, Seo}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @slug_page "/:lang/blog/:slug"
  @category_page "/:lang/blog/:category/:slug"

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "moving-#{n}", host: "moving-#{n}.test", active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
      SettingsState.delete(site.id, "site.languages")
    end)

    register(PageRecords)
    register(PostMoved)

    news = create_collection!(site_id: site.id, slug: "news", status: :active, display_order: 1)
    apps = create_collection!(site_id: site.id, slug: "apps", status: :active, display_order: 2)
    tips = create_collection!(site_id: site.id, slug: "tips", status: :active)

    post = create_blog_post!(site_id: site.id, slug: "hello", status: :published, language: "en")

    for category <- [news, apps],
        do: create_post_collection!(post_id: post.id, collection_id: category.id)

    {:ok, site: site, tips: tips}
  end

  # Registered the way the CMS boot registers it, and unregistered when the test exits.
  defp register(plugin) do
    PluginRegistrations.reconcile(false)
    {:ok, _} = plugin.register()
    {:ok, _} = plugin.start()
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
    :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
  end

  defp page!(site, path, priority \\ 0) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: Ecto.UUID.generate(),
        site: site.name,
        path: path,
        title: path,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: priority,
        language: nil,
        record: "blog:post"
      })
  end

  defp lookup(site, path), do: Redirects.lookup(site.id, path, "")

  test "a post moves: core asks the blog for its old addresses" do
    assert Seo.moves?("blog:post")
    refute Seo.moves?("blog:category")
  end

  describe "on a site whose post page names its category" do
    setup %{site: site} do
      page!(site, @slug_page)
      page!(site, @category_page, 1)
      :ok
    end

    test "a category the post is not filed in, or none the site has, is sent to its own address",
         %{site: site, tips: tips} do
      for category <- [tips.slug, "no-such-category"] do
        assert lookup(site, "/blog/#{category}/hello") == {:redirect, "/blog/news/hello", 301}
      end
    end

    test "another of its categories is its page, not a redirect", %{site: site} do
      assert lookup(site, "/blog/apps/hello") == nil
      assert lookup(site, "/blog/news/hello") == nil
    end

    test "the slug page sends a post filed under a category to its own address", %{site: site} do
      assert lookup(site, "/blog/hello") == {:redirect, "/blog/news/hello", 301}
    end

    test "a post filed under nothing stays at the slug page", %{site: site} do
      create_blog_post!(site_id: site.id, slug: "loose", status: :published, language: "en")

      assert lookup(site, "/blog/loose") == nil
    end

    test "a slug no published post has is left to the page's 404", %{site: site} do
      create_blog_post!(site_id: site.id, slug: "draft", status: :draft, language: "en")

      assert lookup(site, "/blog/news/nobody") == nil
      assert lookup(site, "/blog/news/draft") == nil
      assert lookup(site, "/blog/draft") == nil
    end

    test "keeps the visitor's query on the way", %{site: site} do
      assert Redirects.lookup(site.id, "/blog/tips/hello", "utm_source=x") ==
               {:redirect, "/blog/news/hello?utm_source=x", 301}
    end
  end

  describe "on a site whose post page is the slug page alone" do
    test "a post's own address reads nothing and answers nothing", %{site: site} do
      page!(site, @slug_page)

      assert queries_while(fn -> assert lookup(site, "/blog/hello") == nil end) == []
    end
  end

  test "an answer another plugin gave is handed on" do
    assert PostMoved.call({"/elsewhere", 302}, %{record: "blog:post"}) ==
             {:reply, {"/elsewhere", 302}}
  end
end
