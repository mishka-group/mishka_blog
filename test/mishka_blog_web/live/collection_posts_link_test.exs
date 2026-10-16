# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.CollectionPostsLinkTest do
  @moduledoc """
  Clicking a collection's title opens the posts page showing that collection's posts.

  Two halves have to agree for that to work, and each fails silently on its own: the collections page
  has to emit `?posts_filter_collection_id=<id>`, and `MishkaBlog.BlogPost` has to DECLARE a filter of
  that name — Gervaz's `UrlSync` allowlists declared filter names and drops anything else without a
  word, so a link naming a filter that does not exist just lands on an unfiltered list.

  The filter also has to traverse the right relationship. `BlogPost` has three paths to a collection
  and only two of them are correct here: `:collections` reads through `:public_list`, which is
  `status == :active` only, so a draft collection resolves to zero posts through it. These pin the
  master and tenant paths against a collection that is deliberately NOT active.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @collections_path "/admin/dashboard/blog/collections"
  @posts_path "/admin/dashboard/blog/posts"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = master_site()

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    # A DRAFT collection on purpose: an active one would pass even through the wrong relationship.
    collection = create_collection!(site_id: site.id, status: :draft)
    mine = create_blog_post!(site_id: site.id, title: "Belongs To The Collection")
    theirs = create_blog_post!(site_id: site.id, title: "Not In The Collection")

    MishkaBlog.PostCollection
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false, tenant: site.id)
    |> Ash.Changeset.force_change_attribute(:post_id, mine.id)
    |> Ash.Changeset.force_change_attribute(:collection_id, collection.id)
    |> Ash.create!()

    {:ok, conn: conn, site: site, collection: collection, mine: mine, theirs: theirs}
  end

  test "the collections page links each title to that collection's posts", %{
    conn: conn,
    collection: collection
  } do
    conn = log_in(conn, create_admin("collections@example.com"))

    {:ok, view, _html} = live(conn, @collections_path)
    render_async(view)

    assert has_element?(
             view,
             "a[href='#{@posts_path}?posts_filter_collection_id=#{collection.id}']"
           )
  end

  test "following that link narrows the posts page to the collection", %{
    conn: conn,
    collection: collection,
    mine: mine,
    theirs: theirs
  } do
    conn = log_in(conn, create_admin("posts@example.com"))

    {:ok, view, _html} =
      live(conn, "#{@posts_path}?posts_filter_collection_id=#{collection.id}")

    html = render_async(view)

    assert html =~ mine.title
    refute html =~ theirs.title
  end

  # Arriving by URL is the only way the Collection filter is ever pre-set, and the dropdown's options
  # are a search page of arbitrary collections — so unless the active one is merged in and sorted to
  # the top, the filter reads as "no collection chosen" while the list behind it is filtered.
  test "the posts page shows which collection it is filtered by", %{
    conn: conn,
    collection: collection
  } do
    conn = log_in(conn, create_admin("selected@example.com"))

    {:ok, view, _html} =
      live(conn, "#{@posts_path}?posts_filter_collection_id=#{collection.id}")

    assert render_async(view) =~ collection.name
  end

  # The options list is paged (15 at a time), so the collection a link selected may not be on the
  # first page at all — or on any page yet loaded. It is fetched by id and merged in regardless, and
  # sorted to the top, so the open dropdown always leads with what is actually selected.
  test "the selected collection leads the dropdown even when it would sort onto a later page", %{
    conn: conn,
    site: site
  } do
    for n <- 1..20, do: create_collection!(site_id: site.id, name: "AAA Filler #{n}")
    late = create_collection!(site_id: site.id, name: "ZZZ Sorts Last")

    conn = log_in(conn, create_admin("paged@example.com"))

    {:ok, view, _html} = live(conn, "#{@posts_path}?posts_filter_collection_id=#{late.id}")
    render_async(view)

    html =
      view
      |> element("input[name='_search_collection_id']")
      |> render_focus()

    labels =
      Regex.scan(~r/phx-value-label="([^"]*)"/, html)
      |> Enum.map(fn [_, label] -> label end)

    assert labels != []
    assert hd(labels) == late.name
  end

  test "without the param the posts page still shows everything", %{
    conn: conn,
    mine: mine,
    theirs: theirs
  } do
    conn = log_in(conn, create_admin("unfiltered@example.com"))

    {:ok, view, _html} = live(conn, @posts_path)
    html = render_async(view)

    assert html =~ mine.title
    assert html =~ theirs.title
  end

  defp master_site do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.filter(master == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_site!(name: "localhost", host: "localhost", active: true, master: true)
      site -> site
    end
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
