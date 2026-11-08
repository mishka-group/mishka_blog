# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.AddressTest do
  @moduledoc """
  `MishkaBlog.Address`: a row is linked at the path of the site's page for its kind, whatever that
  path is — the defaults the blog provisions, or the addresses a WordPress site kept — and a post's
  number is the next free one of its site unless the write names it.

  `async: false` — the routing table, the site table and the settings cache are process-global.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.{Address, BlogPost}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "addresses-#{n}", host: "addresses-#{n}.test", active: true)

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

    {:ok, site: site}
  end

  defp page!(site, path, record \\ nil) do
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

  defp post(attrs) do
    struct(
      BlogPost,
      Map.merge(
        %{slug: "hello", language: "en", published_at: ~U[2026-05-07 08:00:00Z], number: 7},
        attrs
      )
    )
  end

  describe "a post's address" do
    test "is the site's post page filled from the post, in any WordPress shape", %{site: site} do
      for {path, en, fa} <- [
            {"/:lang/blog/:slug", "/blog/hello", "/fa/blog/hello"},
            {"/:lang/:slug", "/hello", "/fa/hello"},
            {"/:lang/:year/:monthnum/:slug", "/2026/05/hello", "/fa/2026/05/hello"},
            {"/:lang/:year/:monthnum/:day/:slug", "/2026/05/07/hello", "/fa/2026/05/07/hello"},
            {"/:lang/archives/:post_id", "/archives/7", "/fa/archives/7"},
            {"/index.php/:lang/archives/:post_id", "/index.php/en/archives/7",
             "/index.php/fa/archives/7"}
          ] do
        WebRunTimeMetaDataState.delete_by_site(site.name)
        page!(site, path, "blog:post")

        assert Address.of(post(%{}), site.id) == en, path
        assert Address.of(post(%{language: "fa"}), site.id) == fa, path
      end
    end

    test "carries its first category's slug, and a Persian slug percent-encoded", %{site: site} do
      page!(site, "/:lang/:category/:slug", "blog:post")

      post = post(%{slug: "سلام-دنیا", language: "fa", first_category_slug: "آموزش"})

      assert Address.of(post, site.id) ==
               "/fa/" <> URI.encode("آموزش") <> "/" <> URI.encode("سلام-دنیا")

      assert Address.of(post(%{first_category_slug: nil}), site.id) == nil
    end

    test "is nothing when the site has no post page, or the post cannot fill it", %{site: site} do
      assert Address.of(post(%{}), site.id) == nil

      page!(site, "/:lang/:year/:monthnum/:slug", "blog:post")
      assert Address.of(post(%{published_at: nil}), site.id) == nil
    end

    test "agrees with a request only when its date, number and category are the post's" do
      post = post(%{collections: [%{slug: "news"}, %{slug: "elixir"}]})

      assert Address.agrees?(post, %{"slug" => "hello", "year" => "2026", "monthnum" => "05"})
      assert Address.agrees?(post, %{"monthnum" => "5", "day" => "07", "post_id" => "7"})
      assert Address.agrees?(post, %{"category" => "elixir"})
      refute Address.agrees?(post, %{"year" => "2025"})
      refute Address.agrees?(post, %{"post_id" => "8"})
      refute Address.agrees?(post, %{"category" => "other"})
      refute Address.agrees?(post, %{"monthnum" => "may"})
    end
  end

  describe "a category's address" do
    test "is its whole chain at a page ending in *slug, and its own slug at a :slug one", %{
      site: site
    } do
      category = %MishkaBlog.Collection{
        slug: "berlin",
        language: "en",
        slug_path: "travel/berlin"
      }

      page!(site, "/:lang/category/*slug", "blog:category")
      assert Address.of(category, site.id) == "/category/travel/berlin"
      assert Address.of(%{category | slug_path: nil}, site.id) == "/category/berlin"
      assert Address.loads(MishkaBlog.Collection, "/:lang/category/*slug") == [:slug_path]

      WebRunTimeMetaDataState.delete_by_site(site.name)
      page!(site, "/:lang/category/:slug", "blog:category")
      assert Address.of(category, site.id) == "/category/berlin"
      assert Address.loads(MishkaBlog.Collection, "/:lang/category/:slug") == []
    end

    test "agrees with a request whose chain is its own, or that names it by its slug" do
      category = %MishkaBlog.Collection{slug: "berlin", slug_path: "travel/berlin"}

      assert Address.agrees?(category, %{"slug" => "berlin", "chain" => "travel/berlin"})
      assert Address.agrees?(category, %{"slug" => "berlin"})
      refute Address.agrees?(category, %{"slug" => "berlin", "chain" => "food/berlin"})
    end
  end

  describe "a post's number" do
    test "is the next free one of its site, unless the write names it", %{site: site} do
      other = create_site!()

      first = create_blog_post!(site_id: site.id)
      second = create_blog_post!(site_id: site.id)
      assert second.number == first.number + 1

      named = create_blog_post!(site_id: site.id, number: 500)
      assert named.number == 500
      assert create_blog_post!(site_id: site.id).number == 501

      assert create_blog_post!(site_id: other.id).number == 1

      assert_raise Ash.Error.Invalid, ~r/number/, fn ->
        create_blog_post!(site_id: site.id, number: 500)
      end
    end
  end

  describe "a post whose address is a page of the site" do
    setup %{site: site} do
      page!(site, "/:lang/:slug", "blog:post")
      page!(site, "/about")
      page!(site, "/:lang/contact")
      :ok
    end

    test "is refused, with the address in the message", %{site: site} do
      for slug <- ["about", "contact"] do
        error =
          assert_raise Ash.Error.Invalid, fn ->
            create_blog_post!(site_id: site.id, slug: slug, language: "en")
          end

        assert Exception.message(error) =~ "already a page of this site"
      end
    end

    test "is let through when the address is free, in a Persian slug too", %{site: site} do
      assert %BlogPost{} = create_blog_post!(site_id: site.id, slug: "about-us", language: "en")
      assert %BlogPost{} = create_blog_post!(site_id: site.id, slug: "درباره", language: "fa")
    end
  end
end
