# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.VersionsModalTest do
  @moduledoc """
  The versions modal of each admin list page, driven through the events the page's own buttons send:
  the row action that opens it, a version's Show and Restore buttons, the pager and the modal's
  close.

  All five pages — tags, collections, teams, bloggers and posts — share one helper
  (`MishkaBlogWeb.Live.Admin.Dashboard.VersionsModal`), so each case runs on every page, for a master
  and for a site's admin.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @versions_per_page 10

  # page path, panel id, modal id, resource, text field, record name, not-found flash
  @pages [
    {"tags", "tag-versions", "tag-versions-modal", MishkaBlog.Tag, :name, &__MODULE__.tag!/1,
     "Tag not found or access denied"},
    {"collections", "collection-versions", "collection-versions-modal", MishkaBlog.Collection,
     :name, &__MODULE__.collection!/1, "Collection not found or access denied"},
    {"teams", "team-versions", "team-versions-modal", MishkaBlog.Team, :name, &__MODULE__.team!/1,
     "Team not found or access denied"},
    {"bloggers", "blogger-versions", "blogger-versions-modal", MishkaBlog.Blogger, :display_name,
     &__MODULE__.blogger!/1, "Blogger not found or access denied"},
    {"posts", "post-versions", "post-versions-modal", MishkaBlog.BlogPost, :title,
     &__MODULE__.post!/1, "Post not found or access denied"}
  ]

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    {:ok, conn: conn}
  end

  for {who, master?} <- [{"a master", true}, {"a site's admin", false}] do
    describe who do
      setup %{conn: conn} do
        if unquote(master?) do
          site = master_site()
          remember(site)
          n = System.unique_integer([:positive])

          conn =
            conn
            |> on_host(site.host)
            |> log_in(create_admin("versions-modal-#{n}@example.com", nil), master_mode: true)

          {:ok, conn: conn, site: site}
        else
          n = System.unique_integer([:positive])
          site = create_site!(host: "modal-#{n}.localhost")
          remember(site)

          conn =
            conn
            |> on_host(site.host)
            |> log_in(create_admin("versions-modal-site-#{n}@example.com", site.id), [])

          {:ok, conn: conn, site: site}
        end
      end

      for {page, panel, modal, resource, field, make, not_found} <- @pages do
        test "opens a #{page} record's versions with its name in the head", %{
          conn: conn,
          site: site
        } do
          record = unquote(make).(site)
          version = first_version(unquote(resource), record.id)

          view = open_versions(conn, unquote(page), record)

          assert has_element?(view, "##{unquote(panel)}-#{version.id}")

          assert has_element?(
                   view,
                   "##{unquote(modal)}",
                   to_string(Map.fetch!(record, unquote(field)))
                 )
        end

        test "Show opens a #{page} version's changes and a second Show closes them", %{
          conn: conn,
          site: site
        } do
          record = unquote(make).(site)
          version = first_version(unquote(resource), record.id)
          view = open_versions(conn, unquote(page), record)

          toggle =
            ~s(button[phx-click="toggle_version_preview"][phx-value-version-id="#{version.id}"])

          assert has_element?(view, toggle <> ~s([aria-expanded="false"]))

          view |> element(toggle) |> render_click()
          assert has_element?(view, toggle <> ~s([aria-expanded="true"]))

          view |> element(toggle) |> render_click()
          assert has_element?(view, toggle <> ~s([aria-expanded="false"]))
        end

        test "the pager walks a #{page} record's versions and stops at both ends", %{
          conn: conn,
          site: site
        } do
          record = unquote(make).(site)
          many_versions(record, unquote(field), @versions_per_page + 1)
          view = open_versions(conn, unquote(page), record)
          pager = "##{unquote(panel)}-pager"
          next = ~s(#{pager} button[phx-click="versions_next_page"])
          previous = ~s(#{pager} button[phx-click="versions_prev_page"])

          assert has_element?(view, pager, "1 / 2")
          assert has_element?(view, previous <> "[disabled]")

          view |> element(next) |> render_click()
          render_async(view, @await)
          assert has_element?(view, pager, "2 / 2")
          assert has_element?(view, next <> "[disabled]")

          view |> element(previous) |> render_click()
          render_async(view, @await)
          assert has_element?(view, pager, "1 / 2")
        end

        test "closing the modal forgets the #{page} versions", %{conn: conn, site: site} do
          record = unquote(make).(site)
          version = first_version(unquote(resource), record.id)
          view = open_versions(conn, unquote(page), record)

          assert has_element?(view, "##{unquote(panel)}-#{version.id}")

          render_hook(view, "close_versions", %{})

          refute has_element?(view, "##{unquote(panel)}-#{version.id}")
        end

        test "Restore puts an older #{page} version back, closes the modal and says so", %{
          conn: conn,
          site: site
        } do
          resource = unquote(resource)
          field = unquote(field)
          record = unquote(make).(site)
          before = Map.fetch!(record, field)
          version = first_version(resource, record.id)
          change_field(record, field, "#{before} changed", site)
          view = open_versions(conn, unquote(page), record)

          view
          |> element(
            ~s(button[phx-click="restore_version"][phx-value-version-id="#{version.id}"])
          )
          |> render_click()

          assert Map.fetch!(read(resource, record, site), field) == before
          assert has_element?(view, "#flash-info", "Version restored successfully")
          refute has_element?(view, "##{unquote(panel)}-#{version.id}")
        end

        test "Restore of another #{page} record's version is refused and changes nothing", %{
          conn: conn,
          site: site
        } do
          resource = unquote(resource)
          field = unquote(field)
          record = unquote(make).(site)
          sibling = unquote(make).(site)
          foreign = first_version(resource, sibling.id)
          before = Map.fetch!(read(resource, record, site), field)
          view = open_versions(conn, unquote(page), record)

          html = render_hook(view, "restore_version", %{"version-id" => foreign.id})

          assert html =~ "Version does not belong to this"
          assert has_element?(view, "#flash-error")
          assert Map.fetch!(read(resource, record, site), field) == before
        end

        test "a #{page} record that cannot be read closes the modal with a flash", %{conn: conn} do
          view = open_versions(conn, unquote(page), %{id: Ash.UUID.generate()})

          assert has_element?(view, "#flash-error", unquote(not_found))
        end
      end
    end
  end

  describe "a collection with a translation" do
    test "its language chip switches which edition's versions the modal lists", %{conn: conn} do
      site = master_site()
      remember(site)
      n = System.unique_integer([:positive])

      conn =
        conn
        |> on_host(site.host)
        |> log_in(create_admin("versions-modal-editions-#{n}@example.com", nil),
          master_mode: true
        )

      master = create_collection!(site_id: site.id, name: "Guides #{n}")

      persian =
        create_collection!(
          site_id: site.id,
          name: "Guides #{n} fa",
          language: "fa",
          language_group_id: master.id
        )

      persian_version = first_version(MishkaBlog.Collection, persian.id)
      view = open_versions(conn, "collections", master)

      refute has_element?(view, "#collection-versions-#{persian_version.id}")

      view
      |> element(
        ~s(#collection-versions-modal button[phx-click="show_versions_for"][phx-value-id="#{persian.id}"])
      )
      |> render_click()

      render_async(view, @await)

      assert has_element?(view, "#collection-versions-#{persian_version.id}")
      assert has_element?(view, "#collection-versions-modal", persian.name)
    end
  end

  def tag!(site), do: create_blog_tag!(site_id: site.id)
  def collection!(site), do: create_collection!(site_id: site.id)
  def team!(site), do: create_team!(site_id: site.id)
  def blogger!(site), do: create_blogger!(site_id: site.id)
  def post!(site), do: create_blog_post!(site_id: site.id)

  defp open_versions(conn, page, record) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/#{page}")
    render_async(view, @await)

    send(view.pid, {:row_action, "show_versions", %{"id" => record.id}})
    render_async(view, @await)
    view
  end

  defp read(resource, record, site) do
    Ash.get!(resource, record.id, tenant: site.id, authorize?: false)
  end

  defp change_field(record, field, value, site) do
    record
    |> Ash.Changeset.for_update(:update, %{field => value}, tenant: site.id, authorize?: false)
    |> Ash.update!()
  end

  defp many_versions(record, field, count) do
    Enum.reduce(1..count, record, fn index, current ->
      change_field(
        current,
        field,
        "#{Map.fetch!(record, field)} #{index}",
        %{id: record.site_id}
      )
    end)
  end

  defp first_version(resource, id) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp remember(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp on_host(conn, host) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
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

  defp create_admin(email, site_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false,
        tenant: site_id
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user, opts) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> then(&if(opts[:master_mode], do: Plug.Conn.put_session(&1, :master_mode, true), else: &1))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
