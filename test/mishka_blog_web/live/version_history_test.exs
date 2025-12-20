defmodule MishkaBlogWeb.Test.VersionHistoryTest do
  @moduledoc """
  Each admin list's versions panel lists the record's history, for a master and for a site's admin.

  A version is read as the person asking — a master reads every site's, a site's admin its own
  site's — so each page reads the history with the signed-in user.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000

  @pages [
    {"tags", MishkaBlog.Tag, &__MODULE__.tag!/1},
    {"collections", MishkaBlog.Collection, &__MODULE__.collection!/1},
    {"teams", MishkaBlog.Team, &__MODULE__.team!/1},
    {"bloggers", MishkaBlog.Blogger, &__MODULE__.blogger!/1},
    {"posts", MishkaBlog.BlogPost, &__MODULE__.post!/1}
  ]

  @panels %{
    "tags" => {"tag-versions", :name},
    "collections" => {"collection-versions", :name},
    "teams" => {"team-versions", :name},
    "bloggers" => {"blogger-versions", :display_name},
    "posts" => {"post-versions", :title}
  }

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    {:ok, conn: conn}
  end

  describe "a master" do
    setup %{conn: conn} do
      site = master_site()
      remember(site)
      n = System.unique_integer([:positive])

      conn =
        conn
        |> on_host(site.host)
        |> log_in(create_admin("version-history-#{n}@example.com", nil), master_mode: true)

      {:ok, conn: conn, site: site}
    end

    for {page, resource, make} <- @pages do
      test "sees a #{page} record's versions", %{conn: conn, site: site} do
        record = unquote(make).(site)
        version = first_version(unquote(resource), record.id)

        view = open_versions(conn, unquote(page), record)

        assert has_element?(view, version_row(version))
      end

      test "sees who wrote each #{page} version by email", %{conn: conn} do
        site = create_site!(host: "authors-#{System.unique_integer([:positive])}.localhost")
        {by_colleague, by_master, colleague, master} = authored_versions(unquote(page), site)

        view = open_versions(conn, unquote(page), %{id: by_colleague.version_source_id})
        panel = unquote(page) |> panel() |> elem(0)

        assert author_text(view, panel, by_colleague) == to_string(colleague.email)
        assert author_text(view, panel, by_master) == to_string(master.email)
      end
    end
  end

  describe "a site's admin" do
    setup %{conn: conn} do
      site = create_site!(host: "site-#{System.unique_integer([:positive])}.localhost")
      remember(site)
      n = System.unique_integer([:positive])

      conn =
        conn
        |> on_host(site.host)
        |> log_in(create_admin("version-history-site-#{n}@example.com", site.id), [])

      {:ok, conn: conn, site: site}
    end

    for {page, resource, make} <- @pages do
      test "sees its own #{page} record's versions", %{conn: conn, site: site} do
        record = unquote(make).(site)
        version = first_version(unquote(resource), record.id)

        view = open_versions(conn, unquote(page), record)

        assert has_element?(view, version_row(version))
      end

      test "sees its own people by email and a master as Master on a #{page} version", %{
        conn: conn,
        site: site
      } do
        {by_colleague, by_master, colleague, master} = authored_versions(unquote(page), site)

        view = open_versions(conn, unquote(page), %{id: by_colleague.version_source_id})
        panel = unquote(page) |> panel() |> elem(0)

        assert author_text(view, panel, by_colleague) == to_string(colleague.email)
        assert author_text(view, panel, by_master) == "Master"

        master_email = to_string(master.email)
        refute render(view) =~ master_email
        refute render(view) =~ master_email |> String.split("@") |> hd()
      end
    end
  end

  defp panel(page), do: Map.fetch!(@panels, page)

  # One version written by a user of `site` and one by a master, newest first.
  defp authored_versions(page, site) do
    {_page, resource, make} = List.keyfind(@pages, page, 0)
    {_panel, field} = panel(page)
    n = System.unique_integer([:positive])
    colleague = create_admin("author-colleague-#{n}@example.com", site.id)
    master = create_admin("author-master-#{n}@platform.test", nil)
    record = make.(site)

    record = update_as(record, field, colleague, site, "by colleague")
    by_colleague = latest_version(resource, record.id)
    record = update_as(record, field, master, site, "by master")
    by_master = latest_version(resource, record.id)

    {by_colleague, by_master, colleague, master}
  end

  defp update_as(record, field, actor, site, suffix) do
    record
    |> Ash.Changeset.for_update(:update, %{field => "#{Map.fetch!(record, field)} #{suffix}"},
      tenant: site.id,
      actor: actor,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp latest_version(resource, id) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp author_text(view, panel, version) do
    view
    |> element("##{panel}-#{version.id}-author")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
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

  defp version_row(version),
    do: ~s([phx-click="restore_version"][phx-value-version-id="#{version.id}"])

  defp first_version(resource, id) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^id)
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
