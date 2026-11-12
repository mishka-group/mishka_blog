# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.KeepOldAddressTest do
  @moduledoc """
  `MishkaBlog.Resources.Changes.KeepOldAddress`: a save that moves a shown post, category, tag,
  blogger or team leaves a 301 from its old address to the new one among the site's redirect rules,
  with no chain, no loop and no hand-written rule touched; a draft writes nothing.

  `async: false`: the routing table, the site table and the settings cache are process-global.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Redirect

  alias MishkaCmsCore.Runtime.States.{
    RedirectsState,
    SettingsState,
    SiteState,
    WebRunTimeMetaDataState
  }

  alias MishkaCmsCore.Settings

  @pages [
    {"/:lang/blog/:slug", "blog:post"},
    {"/:lang/blog/category/:slug", "blog:category"},
    {"/:lang/blog/tag/:slug", "blog:tag"},
    {"/:lang/blog/author/:slug", "blog:author"},
    {"/:lang/blog/team/:slug", "blog:team"}
  ]

  @editor "admin:dashboard:blog:post"

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "moved-#{n}", host: "moved-#{n}.test", active: true)

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

    for {path, record} <- @pages, do: page!(site, path, record)

    {:ok, site: site, editor: create_user_with_permissions!([@editor], site_id: site.id)}
  end

  defp page!(site, path, record) do
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

  defp post!(site, attrs) do
    [site_id: site.id, status: :published, language: "en"]
    |> Keyword.merge(attrs)
    |> create_blog_post!()
  end

  defp save(row, params, opts \\ []) do
    row
    |> Ash.Changeset.for_update(
      Keyword.get(opts, :action, :update),
      params,
      Keyword.merge([tenant: row.site_id, authorize?: false], opts)
    )
    |> Ash.update()
  end

  defp rules(site) do
    Redirect
    |> Ash.Query.sort(:from_path)
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.map(&{&1.from_path, &1.to, &1.status, &1.active})
  end

  defp rule!(site, from, to, attrs \\ %{}) do
    Redirect
    |> Ash.Changeset.for_create(:create, Map.merge(%{from_path: from, to: to}, attrs),
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "a post" do
    test "whose slug changes leaves one 301 from its old address, written for an editor without the redirect section",
         %{site: site, editor: editor} do
      post = post!(site, slug: "hello-world")

      assert {:ok, _post} =
               save(post, %{slug: "hello-everyone"}, actor: editor, authorize?: true)

      assert rules(site) == [{"/blog/hello-world", "/blog/hello-everyone", 301, true}]

      _handled = :sys.get_state(RedirectsState)

      assert RedirectsState.lookup(site.id, "/blog/hello-world", nil) ==
               {:redirect, "/blog/hello-everyone", 301}
    end

    test "moved twice leaves no chain: A to C and B to C", %{site: site} do
      post = post!(site, slug: "a")
      {:ok, post} = save(post, %{slug: "b"})
      {:ok, _post} = save(post, %{slug: "c"})

      assert rules(site) == [
               {"/blog/a", "/blog/c", 301, true},
               {"/blog/b", "/blog/c", 301, true}
             ]
    end

    test "moved back to an old address takes that address's rule away, with no loop",
         %{site: site} do
      post = post!(site, slug: "a")
      {:ok, post} = save(post, %{slug: "b"})
      assert {:ok, _post} = save(post, %{slug: "a"})

      assert rules(site) == [{"/blog/b", "/blog/a", 301, true}]

      _handled = :sys.get_state(RedirectsState)
      assert RedirectsState.lookup(site.id, "/blog/a", nil) == nil
      assert RedirectsState.lookup(site.id, "/blog/b", nil) == {:redirect, "/blog/a", 301}
    end

    test "never overwrites a rule written by hand at its old address", %{site: site} do
      post = post!(site, slug: "a")
      own = rule!(site, "/blog/a", "/elsewhere")

      assert {:ok, _post} = save(post, %{slug: "b"})

      assert rules(site) == [{"/blog/a", "/elsewhere", 301, true}]
      assert Ash.get!(Redirect, own.id, tenant: site.id, authorize?: false).to == "/elsewhere"
    end

    test "switches an inactive rule at its old address on, pointed at the new one", %{site: site} do
      post = post!(site, slug: "a")
      off = rule!(site, "/blog/a", "/imported-target", %{active: false, status: 302})

      assert {:ok, _post} = save(post, %{slug: "b"})

      assert rules(site) == [{"/blog/a", "/blog/b", 301, true}]
      assert Ash.get!(Redirect, off.id, tenant: site.id, authorize?: false).active

      _handled = :sys.get_state(RedirectsState)
      assert RedirectsState.lookup(site.id, "/blog/a", nil) == {:redirect, "/blog/b", 301}
    end

    test "points a hand-written redirect to its old address at the new one", %{site: site} do
      post = post!(site, slug: "a")
      rule!(site, "/old-campaign", "/blog/a")

      assert {:ok, _post} = save(post, %{slug: "b"})

      assert rules(site) == [
               {"/blog/a", "/blog/b", 301, true},
               {"/old-campaign", "/blog/b", 301, true}
             ]
    end

    test "as a draft, or saved without moving, writes nothing", %{site: site} do
      draft = post!(site, slug: "draft", status: :draft)
      assert {:ok, _draft} = save(draft, %{slug: "draft-two"})

      shown = post!(site, slug: "kept")
      assert {:ok, _shown} = save(shown, %{title: "A new title"})

      assert rules(site) == []
    end

    test "unpublished by the save writes nothing", %{site: site} do
      post = post!(site, slug: "a")
      assert {:ok, _post} = save(post, %{slug: "b", status: :draft})

      assert rules(site) == []
    end

    test "moved by a master's save or a restored version writes the rule as well", %{site: site} do
      post = post!(site, slug: "a")
      {:ok, post} = save(post, %{slug: "b"}, action: :master_update, tenant: nil)

      [version | _older] =
        BlogPost.Version
        |> Ash.Query.filter(version_source_id == ^post.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(tenant: site.id, authorize?: false)

      assert {:ok, %{slug: "a"}} =
               save(post, %{version_id: version.id}, action: :restore_version)

      assert rules(site) == [{"/blog/b", "/blog/a", 301, true}]
    end

    test "on a page that names its category moves with its first category", %{site: site} do
      WebRunTimeMetaDataState.delete_by_site(site.name)
      page!(site, "/:lang/blog/:category/:slug", "blog:post")

      news = create_collection!(site_id: site.id, slug: "news", status: :active, display_order: 1)
      apps = create_collection!(site_id: site.id, slug: "apps", status: :active, display_order: 2)

      {:ok, post} = save(post!(site, slug: "hello"), %{collection_ids: [apps.id]})
      assert rules(site) == []

      assert {:ok, _post} = save(post, %{collection_ids: [news.id, apps.id]})

      assert rules(site) == [{"/blog/apps/hello", "/blog/news/hello", 301, true}]
    end
  end

  describe "a category, a tag, a blogger and a team" do
    test "whose slug changes each leave a 301, a blogger and a team in every language", %{
      site: site
    } do
      category = create_collection!(site_id: site.id, slug: "news", status: :active)
      tag = create_blog_tag!(site_id: site.id, slug: "elixir")
      blogger = create_blogger!(site_id: site.id, slug: "mona")
      team = create_team!(site_id: site.id, slug: "core", status: :active)

      assert {:ok, %Collection{}} = save(category, %{slug: "updates"})
      assert {:ok, %Tag{}} = save(tag, %{slug: "erlang"})
      assert {:ok, %Blogger{}} = save(blogger, %{slug: "mona-a"})
      assert {:ok, %Team{}} = save(team, %{slug: "engine"})

      assert rules(site) == [
               {"/blog/author/mona", "/blog/author/mona-a", 301, true},
               {"/blog/category/news", "/blog/category/updates", 301, true},
               {"/blog/tag/elixir", "/blog/tag/erlang", 301, true},
               {"/blog/team/core", "/blog/team/engine", 301, true},
               {"/fa/blog/author/mona", "/fa/blog/author/mona-a", 301, true},
               {"/fa/blog/team/core", "/fa/blog/team/engine", 301, true}
             ]
    end

    test "a draft category or team writes nothing", %{site: site} do
      category = create_collection!(site_id: site.id, slug: "news", status: :draft)
      team = create_team!(site_id: site.id, slug: "core", status: :draft)

      assert {:ok, _category} = save(category, %{slug: "updates"})
      assert {:ok, _team} = save(team, %{slug: "engine"})

      assert rules(site) == []
    end
  end
end
