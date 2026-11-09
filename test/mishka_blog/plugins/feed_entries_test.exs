# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedEntriesTest do
  @moduledoc """
  What the blog gives to a site's feeds, read through the feeds core builds
  (`MishkaCmsCore.Feeds.fetch/4`) as a reader would: the newest published posts a guest may open, at
  the address of the page that shows them, with their text, authors and categories; never a draft, a
  scheduled, an archived or a locked post, one of another language or of another site; the feed of a
  category, a tag and a blogger holds the posts filed under it; and a write to a post drops what was
  kept.
  """
  use MishkaBlog.DataCase, async: false

  import SweetXml

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Feeds

  alias MishkaCmsCore.Runtime.States.{
    AssetsState,
    SettingsState,
    SiteState,
    WebRunTimeMetaDataState
  }

  alias MishkaCmsCore.Settings

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "feeds-#{n}", host: "feeds-#{n}.test", active: true)

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

    pages = [
      {"blog:home", "/:lang/blog"}
      | for(
          kind <- ~w(post category tag author)a,
          do: {"blog:#{kind}", Provision.item_paths()[kind]}
        )
    ]

    for {record, path} <- pages do
      :ok =
        WebRunTimeMetaDataState.save(%{
          id: Ecto.UUID.generate(),
          site: site.name,
          path: path,
          title: path,
          created_at: DateTime.utc_now(),
          section: "Page",
          priority: 0,
          language: nil,
          record: record
        })
    end

    on_exit(fn ->
      Feeds.invalidate(site.id)
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, site: site}
  end

  defp post!(site, status, overrides \\ []),
    do: create_blog_post!([site_id: site.id, status: status, language: "en"] ++ overrides)

  defp feed(site, scope \\ :site, format \\ :rss, language \\ "en") do
    {:ok, %{body: body}} = Feeds.fetch(site, scope, language, format)
    body
  end

  defp titles(body), do: xpath(body, ~x"//item/title/text()"sl)

  describe "the site feed" do
    test "lists the published posts of the language, newest first, at their page", %{site: site} do
      old = post!(site, :published, title: "Old", published_at: ~U[2026-01-01 00:00:00Z])
      new = post!(site, :published, title: "New", published_at: ~U[2026-06-01 00:00:00Z])
      post!(site, :published, title: "Persian", language: "fa")

      body = feed(site)

      assert titles(body) == ["New", "Old"]
      assert xpath(body, ~x"//item[1]/link/text()"s) =~ "/blog/#{new.slug}"
      assert xpath(body, ~x"//item[2]/link/text()"s) =~ "/blog/#{old.slug}"
      assert body |> feed_titles_in("fa", site) == ["Persian"]
    end

    test "never lists a draft, a scheduled, an archived or a locked post", %{site: site} do
      post!(site, :published, title: "Open")
      post!(site, :draft, title: "Draft")
      post!(site, :published, title: "Locked", permissions: ["members:read"])

      post!(site, :scheduled,
        title: "Later",
        scheduled_publish_at:
          DateTime.utc_now() |> DateTime.add(3700) |> DateTime.truncate(:second)
      )

      site
      |> post!(:published, title: "Gone")
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      assert titles(feed(site)) == ["Open"]
    end

    test "holds the site's posts only", %{site: site} do
      other = create_site!(active: true)
      post!(site, :published, title: "Mine")
      post!(other, :published, title: "Theirs")

      assert titles(feed(site)) == ["Mine"]
    end

    test "carries the authors and categories, the excerpt else the start of the text", %{
      site: site
    } do
      post =
        post!(site, :published, excerpt: nil, content: "<p>Hello <b>world</b> &amp; all</p>")

      writer = create_blogger!(site_id: site.id, display_name: "Mona Lisa")

      category =
        create_collection!(site_id: site.id, name: "News", status: :active, language: "en")

      create_post_blogger!(post_id: post.id, blogger_id: writer.id)
      create_post_collection!(post_id: post.id, collection_id: category.id)

      body = feed(site)

      assert xpath(body, ~x"//item/dc:creator/text()"s) == "Mona Lisa"
      assert xpath(body, ~x"//item/category/text()"s) == "News"
      assert xpath(body, ~x"//item/description/text()"s) == "Hello world & all"
    end

    test "leaves the text out while the site's feeds.full_content is off", %{site: site} do
      post!(site, :published, content: "<p>Full text</p>")
      assert xpath(feed(site), ~x"//item/content:encoded/text()"s) =~ "Full text"

      {:ok, _} = Settings.put("feeds.full_content", false, site_id: site.id)
      assert xpath(feed(site), ~x"//item/content:encoded"l) == []
    end

    test "follows a write to a post", %{site: site} do
      post!(site, :published, title: "First")
      assert titles(feed(site)) == ["First"]
      assert Enum.any?(AssetsState.types(site.id), &String.starts_with?(&1, "feed:"))

      post!(site, :published, title: "Second")
      assert titles(feed(site)) |> Enum.sort() == ["First", "Second"]
    end
  end

  describe "the feed of a term" do
    test "a category holds the posts filed under it and is named by it", %{site: site} do
      category =
        create_collection!(site_id: site.id, name: "News", status: :active, language: "en")

      filed = post!(site, :published, title: "Filed")
      post!(site, :published, title: "Loose")
      create_post_collection!(post_id: filed.id, collection_id: category.id)

      body = feed(site, {"category", category.slug})

      assert titles(body) == ["Filed"]
      assert xpath(body, ~x"//channel/title/text()"s) =~ "News"
      assert Feeds.fetch(site, {"category", "missing"}, "en", :rss) == :error
    end

    test "a category under another is found by its own slug", %{site: site} do
      parent =
        create_collection!(site_id: site.id, name: "Business", status: :active, language: "en")

      child =
        create_collection!(
          site_id: site.id,
          name: "Case studies",
          status: :active,
          language: "en",
          parent_collection_id: parent.id
        )

      filed = post!(site, :published, title: "Nested")
      create_post_collection!(post_id: filed.id, collection_id: child.id)

      body = feed(site, {"category", child.slug})

      assert titles(body) == ["Nested"]
      assert xpath(body, ~x"//channel/title/text()"s) =~ "Case studies"
    end

    test "a tag holds the posts filed under it", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "en")
      filed = post!(site, :published, title: "Tagged")
      post!(site, :published, title: "Loose")
      create_post_tag!(post_id: filed.id, tag_id: tag.id)

      assert titles(feed(site, {"tag", tag.slug})) == ["Tagged"]
    end

    test "a term is found in the language of the feed only", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "fa")
      filed = post!(site, :published, title: "Persian", language: "fa")
      create_post_tag!(post_id: filed.id, tag_id: tag.id)

      assert titles(feed(site, {"tag", tag.slug}, :rss, "fa")) == ["Persian"]
      assert Feeds.fetch(site, {"tag", tag.slug}, "en", :rss) == :error
    end

    test "a blogger holds their posts, in any language of the feed", %{site: site} do
      writer = create_blogger!(site_id: site.id, slug: "mona")
      mine = post!(site, :published, title: "Mine")
      post!(site, :published, title: "Not mine")
      create_post_blogger!(post_id: mine.id, blogger_id: writer.id)

      assert titles(feed(site, {"author", "mona"})) == ["Mine"]
    end

    test "a kind the blog does not know is no feed", %{site: site} do
      post!(site, :published)
      assert Feeds.fetch(site, {"series", "x"}, "en", :rss) == :error
    end
  end

  defp feed_titles_in(_body, language, site), do: site |> feed(:site, :rss, language) |> titles()
end
