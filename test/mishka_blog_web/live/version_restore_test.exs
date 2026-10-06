defmodule MishkaBlogWeb.Test.VersionRestoreTest do
  @moduledoc """
  A master opens each admin list's versions panel and restores an older version from it.

  Loading the panel and the restore are both master actions, and a master action reads the actor its
  input was built with: built with none it is refused, since a missing actor is nobody. Each page
  builds both with the signed-in master, so the panel lists the versions and the restore goes
  through.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000

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

    admin = create_admin("version-restore-#{System.unique_integer([:positive])}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    {:ok, conn: conn, site: site}
  end

  @pages [
    {"tags", "tag-versions", MishkaBlog.Tag, :name, &__MODULE__.tag!/1},
    {"collections", "collection-versions", MishkaBlog.Collection, :name,
     &__MODULE__.collection!/1},
    {"teams", "team-versions", MishkaBlog.Team, :name, &__MODULE__.team!/1},
    {"bloggers", "blogger-versions", MishkaBlog.Blogger, :display_name, &__MODULE__.blogger!/1},
    {"posts", "post-versions", MishkaBlog.BlogPost, :title, &__MODULE__.post!/1}
  ]

  for {page, panel, resource, field, make} <- @pages do
    test "a master restores an older #{page} version", %{conn: conn, site: site} do
      resource = unquote(resource)
      field = unquote(field)
      record = unquote(make).(site)
      before = Map.fetch!(record, field)

      record
      |> Ash.Changeset.for_update(:update, %{field => "#{before} changed"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      version = first_version(resource, record.id)

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog/#{unquote(page)}")
      render_async(view, @await)

      send(view.pid, {:row_action, "show_versions", %{"id" => record.id}})
      render_async(view, @await)

      assert has_element?(view, "##{unquote(panel)}-#{version.id}")

      render_hook(view, "restore_version", %{"version-id" => version.id})

      assert Map.fetch!(Ash.get!(resource, record.id, tenant: site.id, authorize?: false), field) ==
               before
    end
  end

  def tag!(site), do: create_blog_tag!(site_id: site.id)
  def collection!(site), do: create_collection!(site_id: site.id)
  def team!(site), do: create_team!(site_id: site.id)
  def blogger!(site), do: create_blogger!(site_id: site.id)
  def post!(site), do: create_blog_post!(site_id: site.id)

  defp first_version(resource, id) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
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
