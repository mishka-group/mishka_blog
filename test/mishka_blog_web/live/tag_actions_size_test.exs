# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.TagActionsSizeTest do
  @moduledoc """
  The tag grid sizes only the trigger of a tag's actions menu. The menu's own item buttons sit inside the
  same wrapper, so a size rule written for every `button` there squeezes them into small squares; the
  rule names the trigger by `aria-haspopup`, which the dropdown's trigger carries and its items do not.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

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

    create_blog_tag!(site_id: site.id)
    {:ok, conn: conn}
  end

  test "the size rule reaches the actions trigger and no item of the menu", %{conn: conn} do
    conn = log_in(conn, create_admin("tag-actions@example.com"))
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/tags")
    render_async(view)

    wrapper = view |> element("[data-role='tag-actions']") |> render() |> LazyHTML.from_fragment()

    assert wrapper |> LazyHTML.query("[aria-haspopup]") |> Enum.count() == 1

    assert wrapper
           |> LazyHTML.query("[popover] button, [role=menu] button")
           |> Enum.all?(fn button ->
             button |> LazyHTML.attribute("aria-haspopup") == []
           end)
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
