# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.SettingsTabTest do
  @moduledoc """
  This extension's own tab on the shared Settings page.

  `MishkaBlog.Notifiers.NotifySettings` registers its toggles through the `settings:register` hook, and
  the page that draws them is `MishkaCmsCore`'s — so the only place the two halves meet is here, with
  this extension installed. The core's own tabs are covered by `MishkaCmsCoreWeb.Test.NotifyUITest`.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
    MishkaCmsCore.Settings.load_definitions()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

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

    {:ok, conn: conn}
  end

  test "the Blog tab holds the post toggle under a Notifications group, not the Notifications tab",
       %{conn: conn} do
    admin = create_admin("boss@example.com")
    conn = log_in(conn, admin)

    {:ok, view, _html} = live(conn, "/admin/dashboard/settings")

    html = render_patch(view, "/admin/dashboard/settings?tab=blog")

    assert html =~ "Notify blog admins when a post is published"
    assert has_element?(view, "#settings-form h3", "Notifications")
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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
