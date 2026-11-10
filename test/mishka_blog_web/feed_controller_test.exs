# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.FeedControllerTest do
  @moduledoc """
  The blog's RSS 2.0, Atom 1.0 and JSON Feed 1.1 feeds as a reader fetches them, through the
  `extension_routes(:api)` mount and its gate: each format is parsed back and read for its content;
  only the published posts a guest may open, of the feed's language and site, are in it, at their
  page; a category, a nested category, a tag and a blogger have feeds of their own; an address that
  cannot be a feed, an unknown term and a site with its feeds or the blog off are a 404; a request
  whose `ETag` is the feed's is a `304`; and a write to a post drops what was kept.

  `async: false`: `SiteState`, `AssetsState`, the page index and the settings cache are
  process-global.
  """
  use MishkaBlog.ConnCase, async: false

  import MishkaBlog.Test.Factory
  import SweetXml

  alias MishkaBlog.{Feeds, Provision}

  alias MishkaCmsCore.Runtime.States.{
    AssetsState,
    SettingsState,
    SiteState,
    WebRunTimeMetaDataState
  }

  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    site = site!()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    {:ok, site: site}
  end

  defp site! do
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
    {:ok, _} = Settings.put("site.title", "Feed Site", site_id: site.id)

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
    end)

    site
  end

  defp post!(site, status, overrides \\ []),
    do: create_blog_post!([site_id: site.id, status: status, language: "en"] ++ overrides)

  defp fetch(site, path, headers \\ []) do
    headers
    |> Enum.reduce(build_conn(), fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
    |> get(path)
  end

  defp titles(%Plug.Conn{resp_body: body}), do: titles(body)
  defp titles(body), do: xpath(body, ~x"//item/title/text()"sl)

  defp json_titles(conn),
    do: conn.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["title"])

  describe "RSS 2.0 at /feed" do
    test "lists the published posts of the language, newest first, at their page", %{site: site} do
      old = post!(site, :published, title: "Old", published_at: ~U[2026-01-01 00:00:00Z])
      new = post!(site, :published, title: "New", published_at: ~U[2026-06-01 00:00:00Z])
      post!(site, :published, title: "Persian", language: "fa")

      conn = fetch(site, "/feed", [{"accept", "application/rss+xml, application/xml;q=0.9"}])

      assert conn.status == 200
      assert ["application/rss+xml; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "set-cookie") == []
      assert xpath(conn.resp_body, ~x"//channel/title/text()"s) == "Feed Site"
      assert titles(conn) == ["New", "Old"]
      assert xpath(conn.resp_body, ~x"//item[1]/link/text()"s) =~ "#{site.host}"
      assert xpath(conn.resp_body, ~x"//item[1]/guid/text()"s) =~ "/blog/#{new.slug}"
      assert xpath(conn.resp_body, ~x"//item[1]/guid/@isPermaLink"s) == "true"
      assert xpath(conn.resp_body, ~x"//item[2]/link/text()"s) =~ "/blog/#{old.slug}"

      assert titles(fetch(site, "/fa/feed")) == ["Persian"]
      assert titles(fetch(site, "/feed.rss")) == ["New", "Old"]
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

      assert titles(fetch(site, "/feed")) == ["Open"]
    end

    test "carries the authors and categories, the text in CDATA, the excerpt else the start of the text",
         %{site: site} do
      post =
        post!(site, :published,
          title: "Tom & Jerry <3",
          excerpt: nil,
          content: "<p>Hello <b>world</b> &amp; all</p><script>alert(1)</script>"
        )

      writer = create_blogger!(site_id: site.id, display_name: "Mona Lisa")

      category =
        create_collection!(site_id: site.id, name: "News", status: :active, language: "en")

      create_post_blogger!(post_id: post.id, blogger_id: writer.id)
      create_post_collection!(post_id: post.id, collection_id: category.id)

      body = fetch(site, "/feed").resp_body

      assert titles(body) == ["Tom & Jerry <3"]
      refute body =~ "<script>"
      assert body =~ "<![CDATA["
      assert xpath(body, ~x"//item/dc:creator/text()"s) == "Mona Lisa"
      assert xpath(body, ~x"//item/category/text()"s) == "News"
      assert xpath(body, ~x"//item/description/text()"s) =~ "Hello world & all"
      assert xpath(body, ~x"//item/content:encoded/text()"s) =~ "world"
      refute xpath(body, ~x"//item/content:encoded/text()"s) =~ "<script"
    end

    test "leaves the text out while blog.feeds.full_content is off", %{site: site} do
      post!(site, :published, content: "<p>Full text</p>")

      assert xpath(fetch(site, "/feed").resp_body, ~x"//item/content:encoded/text()"s) =~
               "Full text"

      {:ok, _} = Settings.put("blog.feeds.full_content", false, site_id: site.id)
      assert xpath(fetch(site, "/feed").resp_body, ~x"//item/content:encoded"l) == []
    end

    test "lists at most blog.feeds.items", %{site: site} do
      {:ok, _} = Settings.put("blog.feeds.items", 2, site_id: site.id)

      for day <- 1..4,
          do:
            post!(site, :published,
              title: "Post #{day}",
              published_at: DateTime.new!(Date.add(~D[2026-01-01], day), ~T[00:00:00])
            )

      assert titles(fetch(site, "/feed")) == ["Post 4", "Post 3"]
    end
  end

  describe "Atom 1.0 at /feed/atom and JSON Feed 1.1 at /feed.json" do
    test "the same posts in each format", %{site: site} do
      post!(site, :published, title: "Hello", content: "<p>Body</p>")

      conn = fetch(site, "/feed/atom")
      assert ["application/atom+xml; charset=utf-8"] = get_resp_header(conn, "content-type")

      assert xpath(conn.resp_body, ~x"/*[local-name()='feed']/*[local-name()='title']/text()"s) ==
               "Feed Site"

      assert xpath(conn.resp_body, ~x"//*[local-name()='entry']/*[local-name()='title']/text()"s) ==
               "Hello"

      assert xpath(conn.resp_body, ~x"//*[local-name()='entry']/*[local-name()='content']/@type"s) ==
               "html"

      json = fetch(site, "/feed.json")
      assert ["application/feed+json; charset=utf-8"] = get_resp_header(json, "content-type")
      feed = Jason.decode!(json.resp_body)
      assert feed["version"] == "https://jsonfeed.org/version/1.1"
      assert feed["feed_url"] =~ "#{site.host}"
      assert feed["feed_url"] =~ ~r{/feed\.json$}
      assert json_titles(json) == ["Hello"]
    end
  end

  describe "the feed of a term" do
    test "a category holds the posts filed under it, is named by it, in each format", %{
      site: site
    } do
      category =
        create_collection!(site_id: site.id, name: "News", status: :active, language: "en")

      filed = post!(site, :published, title: "Filed")
      post!(site, :published, title: "Loose")
      create_post_collection!(post_id: filed.id, collection_id: category.id)

      conn = fetch(site, "/feed/category/#{category.slug}")
      assert titles(conn) == ["Filed"]
      assert xpath(conn.resp_body, ~x"//channel/title/text()"s) == "Feed Site - News"
      assert fetch(site, "/feed/category/#{category.slug}/atom").status == 200
      assert json_titles(fetch(site, "/feed/category/#{category.slug}/json")) == ["Filed"]
    end

    test "a nested category answers at its whole chain and at its own slug", %{site: site} do
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
      post!(site, :published, title: "Loose")
      create_post_collection!(post_id: filed.id, collection_id: child.id)

      for path <- [
            "/feed/category/#{child.slug}",
            "/feed/category/#{parent.slug}/#{child.slug}",
            "/feed/category/a/#{parent.slug}/#{child.slug}"
          ] do
        conn = fetch(site, path)
        assert {path, conn.status, titles(conn)} == {path, 200, ["Nested"]}
      end

      atom = fetch(site, "/feed/category/#{parent.slug}/#{child.slug}/atom")
      assert ["application/atom+xml; charset=utf-8"] = get_resp_header(atom, "content-type")

      assert json_titles(fetch(site, "/feed/category/#{parent.slug}/#{child.slug}/json")) == [
               "Nested"
             ]

      assert fetch(site, "/feed/category/#{parent.slug}/missing").status == 404
    end

    test "a tag is found in the language of the feed only", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "fa")
      filed = post!(site, :published, title: "Persian", language: "fa")
      create_post_tag!(post_id: filed.id, tag_id: tag.id)

      assert titles(fetch(site, "/fa/feed/tag/#{tag.slug}")) == ["Persian"]
      assert fetch(site, "/feed/tag/#{tag.slug}").status == 404
    end

    test "a blogger holds their posts", %{site: site} do
      writer = create_blogger!(site_id: site.id, slug: "mona")
      mine = post!(site, :published, title: "Mine")
      post!(site, :published, title: "Not mine")
      create_post_blogger!(post_id: mine.id, blogger_id: writer.id)

      assert titles(fetch(site, "/feed/author/mona")) == ["Mine"]
    end

    test "an unknown term, kind or bad address is a 404 no cache keeps, said as text", %{
      site: site
    } do
      post!(site, :published)

      for path <- [
            "/feed/category/missing",
            "/feed/series/x",
            "/feed/Bad%20Kind/x",
            "/feed/tag/%FF",
            "/feed/tag/" <> String.duplicate("a", 300),
            "/de/feed"
          ] do
        conn = fetch(site, path)
        assert {path, conn.status} == {path, 404}
        assert conn.resp_body == "Not Found"
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
      end
    end
  end

  describe "isolation and switches" do
    test "a site's feed holds its own posts only", %{site: site} do
      other = site!()
      post!(site, :published, title: "Mine")
      post!(other, :published, title: "Theirs")

      assert titles(fetch(site, "/feed")) == ["Mine"]
      assert titles(fetch(other, "/feed")) == ["Theirs"]
    end

    test "is a 404 while blog.feeds.enabled is off", %{site: site} do
      post!(site, :published)
      {:ok, _} = Settings.put("blog.feeds.enabled", false, site_id: site.id)

      assert fetch(site, "/feed").status == 404
    end

    test "is the host's 404 while the site has the blog switched off", %{site: site} do
      post!(site, :published)
      {:ok, _} = Settings.put("mishka_blog.active", false, site_id: site.id)

      assert_error_sent 404, fn -> fetch(site, "/feed") end
    end
  end

  describe "caching" do
    test "an ETag that matches is a 304 with no body, with the newest post's last-modified", %{
      site: site
    } do
      post!(site, :published, title: "Hello")

      first = fetch(site, "/feed")
      assert [etag] = get_resp_header(first, "etag")
      assert [_last_modified] = get_resp_header(first, "last-modified")
      assert ["public, max-age=300"] = get_resp_header(first, "cache-control")

      same = fetch(site, "/feed", [{"if-none-match", etag}])
      assert same.status == 304
      assert same.resp_body == ""

      assert fetch(site, "/feed", [{"if-none-match", "*"}]).status == 304
      assert fetch(site, "/feed", [{"if-none-match", ~s(W/"other")}]).status == 200
    end

    test "is kept until a write to a post drops it", %{site: site} do
      post!(site, :published, title: "First")
      assert titles(fetch(site, "/feed")) == ["First"]
      assert Enum.any?(AssetsState.types(site.id), &String.starts_with?(&1, Feeds.prefix()))

      post!(site, :published, title: "Second")
      assert Enum.sort(titles(fetch(site, "/feed"))) == ["First", "Second"]
    end

    test "a feed with nothing in it is not kept", %{site: site} do
      assert fetch(site, "/feed").status == 200
      refute Enum.any?(AssetsState.types(site.id), &String.starts_with?(&1, Feeds.prefix()))
    end
  end

  describe "paths" do
    test "follow the site's URL mode", %{site: site} do
      assert Feeds.path(:site, :atom, "fa", site.id) == "/fa/feed/atom"
      assert Feeds.path(:site, :atom, "en", site.id) == "/feed/atom"

      assert Feeds.path({"category", "elixir"}, :json, "en", site.id) ==
               "/feed/category/elixir/json"

      assert Feeds.path(:site, :rss, "de", site.id) == nil
    end
  end
end
