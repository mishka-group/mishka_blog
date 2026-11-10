# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedLinksTest do
  @moduledoc """
  The head of a site's page names the blog's feeds in the page's language, and a category's, a
  tag's or a blogger's page also names that term's, from the record the page already read; an admin
  page, a site with its feeds off and a site with the blog off name none.

  `async: false`: `SiteState` and the settings cache are process-global.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.PageSource
  alias MishkaBlog.Plugins.FeedLinks
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    n = System.unique_integer([:positive])
    site = create_site!(name: "links-#{n}", host: "links-#{n}.test", active: true)

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
    {:ok, _} = Settings.put("site.language_urls", "prefix_others", site_id: site.id)
    {:ok, _} = Settings.put("site.title", "Feed Site", site_id: site.id)

    on_exit(fn ->
      SiteState.delete(site.id)
      SettingsState.restore(snapshot)
    end)

    {:ok, site: site}
  end

  defp head(site, assigns) do
    {:reply, %{html: html}} =
      FeedLinks.call(%{
        html: "",
        assigns: Map.merge(%{runtime_page: true, current_site: site}, assigns)
      })

    html
  end

  defp source(kind, record),
    do: %PageSource{site_id: "site", visitor: nil, language: "en", kind: kind, record: record}

  test "a page of the site names its feeds in the page's language", %{site: site} do
    html = head(site, %{site_language: "fa"})

    assert html =~ ~s(type="application/rss+xml")
    assert html =~ ~s(type="application/atom+xml")
    assert html =~ ~s(type="application/feed+json")
    assert html =~ ~s(title="Feed Site")
    assert html =~ "/fa/feed.json"
  end

  test "a term's page names its feeds beside the site's, titled with the term", %{site: site} do
    html =
      head(site, %{
        page_source: source("blog:category", %{slug: "case-studies", name: "Case <studies>"})
      })

    assert html =~ ~s(title="Feed Site - Case &lt;studies&gt;")
    assert html =~ "/feed/category/case-studies\""
    assert html =~ "/feed/category/case-studies/atom"
    assert html =~ "/feed/category/case-studies/json"
    assert html =~ "/feed\""

    assert head(site, %{page_source: source("blog:tag", %{slug: "otp", name: "OTP"})}) =~
             "/feed/tag/otp"

    assert head(site, %{page_source: source("blog:author", %{slug: "mona", display_name: "Mona"})}) =~
             "/feed/author/mona"

    post_page = head(site, %{page_source: source("blog:post", %{slug: "hello", title: "Hello"})})
    refute post_page =~ "/feed/category"
    refute post_page =~ "/feed/tag"
    refute post_page =~ "/feed/author"
  end

  test "an admin page, a site with its feeds off and one with the blog off name none", %{
    site: site
  } do
    assert {:reply, %{html: ""}} =
             FeedLinks.call(%{html: "", assigns: %{admin_css: true, current_site: site}})

    {:ok, _} = Settings.put("blog.feeds.enabled", false, site_id: site.id)
    assert head(site, %{}) == ""

    {:ok, _} = Settings.put("blog.feeds.enabled", true, site_id: site.id)
    {:ok, _} = Settings.put("mishka_blog.active", false, site_id: site.id)
    assert head(site, %{}) == ""
  end
end
