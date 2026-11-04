# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.DashboardActionsTest do
  @moduledoc """
  The buttons an extension adds to the blog dashboard's header on `blog:dashboard:actions`
  (`MishkaBlog.Dashboard.Actions`): drawn only while a plugin answers, a link for a path and a button
  for a `JS` command, and an action that cannot be drawn or repeats an id is dropped.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest

  alias MishkaBlog.Dashboard.Actions
  alias MishkaBlog.Test.Plugins.BlogDashboardActionsProbe
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"
  @event "blog:dashboard:actions"

  setup %{conn: conn} do
    SiteState.clear()
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
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_blog, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, admin: create_admin("actions@example.com")}
  end

  test "no extension button is drawn while no plugin answers", %{conn: conn, admin: admin} do
    assert Actions.collect(admin) == []

    {:ok, view, _html} = conn |> log_in(admin) |> live("/admin/dashboard/blog")
    render_async(view, 5_000)

    refute has_element?(view, "#blog-action-probe-link")
    assert has_element?(view, "#blog-new-post-btn")
  end

  describe "with a plugin answering" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BlogDashboardActionsProbe,
          event: @event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@event, :start, false)
      on_exit(fn -> Event.unregister(:name, BlogDashboardActionsProbe, false) end)
    end

    test "collects the drawable actions, low priority first", %{admin: admin} do
      assert ["probe-js", "probe-link"] == Enum.map(Actions.collect(admin), & &1.id)
      assert %{label: "Probe link"} = Enum.find(Actions.collect(admin), &(&1.id == "probe-link"))
    end

    test "draws a link for a path and a button for a command", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> log_in(admin) |> live("/admin/dashboard/blog")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "a#blog-action-probe-link[href$='/admin/dashboard/blog/tags']",
               "Probe link"
             )

      assert has_element?(view, "button#blog-action-probe-js[phx-click]", "Probe button")
      refute has_element?(view, "#blog-action-probe-bare")
      refute has_element?(view, "#blog-action-probe-both")
      assert has_element?(view, "#blog-analytics-btn")
    end
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
