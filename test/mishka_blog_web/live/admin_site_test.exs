# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.AdminSiteTest do
  @moduledoc """
  The blog's admin pages follow the site a master picked in the top bar
  (`MishkaCmsCore.Accounts.AdminSite`): All sites shows every site's records, each named with its
  site; one site shows that site's records alone, on the dashboard's figures and in the lists; a
  pick made on another page reaches an open page live.
  """
  use MishkaBlog.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{AdminSite, Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()

    home = cached_site!(name: "localhost", host: "localhost", master: true)
    other = cached_site!(name: "beta", host: "beta.test", master: false)

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    for site <- [home, other],
        do: :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_blog, "test")

    create_blog_tag!(site_id: home.id, name: "Home Tag", slug: "home-tag")
    create_blog_tag!(site_id: other.id, name: "Beta Tag One", slug: "beta-tag-one")
    create_blog_tag!(site_id: other.id, name: "Beta Tag Two", slug: "beta-tag-two")

    master = create_master!()

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(master)

    {:ok, conn: conn, master: master, home: home, other: other}
  end

  test "All sites lists every site's tags, each named with its site", %{
    conn: conn,
    home: home,
    other: other
  } do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    html = render_async(view, 5_000)

    assert html =~ "Home Tag"
    assert html =~ "Beta Tag One"
    assert has_element?(view, ~s([data-role="tag-site"][title="#{home.name}"]))
    assert has_element?(view, ~s([data-role="tag-site"][title="#{other.name}"]))
  end

  test "the comments list names each comment's site for All sites, and none for one site", %{
    conn: conn,
    master: master,
    home: home,
    other: other
  } do
    create_comment!(site_id: home.id, content: "Said at home")
    create_comment!(site_id: other.id, content: "Said at beta")

    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/comments")
    render_async(view, 5_000)

    assert has_element?(view, ~s([data-role="comment-site"][title="#{home.name}"]))
    assert has_element?(view, ~s([data-role="comment-site"][title="#{other.name}"]))

    :ok = AdminSite.keep(master, other.id)

    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/comments")
    html = render_async(view, 5_000)

    assert html =~ "Said at beta"
    refute html =~ "Said at home"
    refute has_element?(view, ~s([data-role="comment-site"]))
  end

  test "with one site picked the tags list is that site's alone", %{
    conn: conn,
    master: master,
    other: other
  } do
    :ok = AdminSite.keep(master, other.id)

    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    html = render_async(view, 5_000)

    assert html =~ "Beta Tag One"
    assert html =~ "Beta Tag Two"
    refute html =~ "Home Tag"
    refute has_element?(view, ~s([data-role="tag-site"]))
  end

  test "the dashboard's figures are the picked site's, and every site's for All sites", %{
    conn: conn,
    master: master,
    home: home,
    other: other
  } do
    assert tags_total(conn) == 3

    :ok = AdminSite.keep(master, other.id)
    assert tags_total(conn) == 2

    :ok = AdminSite.keep(master, home.id)
    assert tags_total(conn) == 1

    :ok = AdminSite.keep(master, AdminSite.all())
    assert tags_total(conn) == 3
  end

  test "a pick made on another page opens the open page again in the picked site", %{
    conn: conn,
    master: master,
    other: other
  } do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    render_async(view, 5_000)

    :ok = Task.await(Task.async(fn -> AdminSite.keep(master, other.id) end))

    assert {"/admin/dashboard/blog/tags", _flash} = assert_redirect(view)
  end

  test "a master picks the site in the top bar's switcher on a blog page", %{
    conn: conn,
    master: master,
    home: home,
    other: other
  } do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    render_async(view, 5_000)

    assert has_element?(view, "[data-testid=site-switcher-name]", "All sites")
    assert has_element?(view, "[data-testid=site-switcher-site-#{home.id}]", home.name)

    view |> element("[data-testid=site-switcher-site-#{other.id}]") |> render_click()

    assert {"/admin/dashboard/blog/tags", _flash} = assert_redirect(view)
    assert AdminSite.chosen(master) == other.id

    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    html = render_async(view, 5_000)
    assert has_element?(view, "[data-testid=site-switcher-name]", other.name)
    refute html =~ "Home Tag"
  end

  test "a site's own admin has no switcher on a blog page", %{home: home} do
    site_admin = MishkaCmsCore.Test.Admin.create_admin("blog-site-admin@example.com", home.id)

    {:ok, view, _html} =
      "localhost"
      |> MishkaCmsCore.Test.Admin.build_conn_for_host()
      |> log_in(site_admin)
      |> live("/admin/dashboard/blog/tags")

    render_async(view, 5_000)
    refute has_element?(view, "[data-testid=site-switcher]")
  end

  # The Total Tags figure of the dashboard's Tags card, as the admin reads it.
  defp tags_total(conn) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog")

    text =
      view
      |> render_async(5_000)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="blog-cards"] a[href$="/blog/tags"]))
      |> LazyHTML.text()

    [_text, total] = Regex.run(~r/Total Tags\s*(\d+)/, text)
    String.to_integer(total)
  end

  defp cached_site!(attrs) do
    site = create_site!(Keyword.put(attrs, :active, true))
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    site
  end

  defp create_master! do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: "picker@example.com", password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    star =
      case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one!(authorize?: false) do
        nil ->
          Permission
          |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
          |> Ash.create!()

        permission ->
          permission
      end

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star.id)
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
