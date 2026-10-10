defmodule MishkaBlogWeb.Test.LanguageGroupsTest do
  @moduledoc """
  The posts, collections and tags pages with translated records in them.

  A language group is one record in several languages. Each page lists it as one row — the group's
  master — with a badge per language, each badge opening that edition for editing, and a search by
  title finds the group through any of its languages. See `MishkaCmsCore.LanguageEditions` for the
  rule and `MishkaBlogWeb.Templates.EditionChips` for the badges.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @repo Application.compile_env!(:mishka_cms_core, :repo)

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

    n = System.unique_integer([:positive])

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin("language-groups-#{n}@example.com"))

    {:ok, conn: conn, site: site, n: n}
  end

  for {resource, path, role, field, table, cell} <- [
        {BlogPost, "/admin/dashboard/blog/posts", "bp-row", :title, "mishka_blog_posts", "post"},
        {Collection, "/admin/dashboard/blog/collections", "colcard", :name,
         "mishka_blog_collections", "collection"},
        {Tag, "/admin/dashboard/blog/tags", "tagchip", :name, "mishka_blog_tags", "tag"}
      ] do
    @resource resource
    @path path
    @role role
    @field field
    @table table
    @cell cell
    @label inspect(resource)

    describe "#{inspect(resource)}" do
      test "a language group is one row with a badge for each of its languages", ctx do
        %{master: master, fa: fa, ar: ar} = group(ctx, @resource)
        view = open(ctx.conn, @path)

        assert has_element?(view, card(@role, master))
        refute has_element?(view, card(@role, fa)), "#{@label}: the Persian edition took a row"
        refute has_element?(view, card(@role, ar)), "#{@label}: the Arabic edition took a row"

        for edition <- [master, fa, ar] do
          assert has_element?(view, chip(@role, master, edition)),
                 "#{@label}: no badge for #{edition.language}"
        end

        assert has_element?(view, chip(@role, master, fa), "FA")
      end

      test "a record in a group of its own has no badges and still shows", ctx do
        alone = make(@resource, ctx.site, ctx.n, "alone")
        ungrouped = make(@resource, ctx.site, ctx.n, "ungrouped")
        ungroup!(@table, ungrouped)

        view = open(ctx.conn, @path)

        for record <- [alone, ungrouped] do
          assert has_element?(view, card(@role, record))
          refute has_element?(view, ~s(#{card(@role, record)} [phx-click="show_edition"]))
        end
      end

      test "a badge opens its own edition for editing", ctx do
        %{master: master, fa: fa} = group(ctx, @resource)
        view = open(ctx.conn, @path)

        view |> element(chip(@role, master, fa)) |> render_click()
        render_async(view, @await)

        form = view |> element("form[method=put]") |> render()

        assert form =~ Map.fetch!(fa, @field), "#{@label}: the form did not open the edition"
      end

      test "the search finds the group by the title of any of its languages", ctx do
        %{master: master, fa: fa} = group(ctx, @resource)
        view = open(ctx.conn, @path)

        search(view, @resource, Map.fetch!(fa, @field))

        assert has_element?(view, card(@role, fa)), "#{@label}: the search missed the edition"
        refute has_element?(view, card(@role, master))
        assert has_element?(view, chip(@role, fa, master)), "the found edition lost its badges"

        search(view, @resource, "")

        assert has_element?(view, card(@role, master))
        refute has_element?(view, card(@role, fa)), "#{@label}: the list stayed expanded"
      end

      test "the language filter lists the editions of that language on their own", ctx do
        %{master: master, fa: fa} = group(ctx, @resource)
        view = open(ctx.conn, @path)

        view
        |> form(filter_form(@resource), %{"language" => "fa"})
        |> render_change()

        render_async(view, @await)

        assert has_element?(view, card(@role, fa))
        refute has_element?(view, card(@role, master))
      end

      test "the table view lists the group in one row with the same badges", ctx do
        %{master: master, fa: fa, ar: ar} = group(ctx, @resource)
        view = open(ctx.conn, @path)

        view
        |> element(~s([phx-click="switch_template"][phx-value-template="table"]))
        |> render_click()

        render_async(view, @await)

        cell = fn record -> "##{@cell}-editions-#{record.id}" end

        assert has_element?(view, cell.(master))
        refute has_element?(view, cell.(fa)), "#{@label}: the Persian edition took a row"

        for edition <- [master, fa, ar] do
          assert has_element?(view, ~s(#{cell.(master)} button[phx-value-id="#{edition.id}"]))
        end

        open_edition(view, ~s(#{cell.(master)} button[phx-value-id="#{fa.id}"]))

        form = view |> element("form[method=put]") |> render()
        assert form =~ Map.fetch!(fa, @field), "#{@label}: the badge did not open the edition"
      end

      test "a translation added while the page is open joins its master's row", ctx do
        master = make(@resource, ctx.site, ctx.n, "master")
        view = open(ctx.conn, @path)

        fa = make(@resource, ctx.site, ctx.n, "fa", language: "fa", language_group_id: master.id)
        settle(view)

        refute has_element?(view, card(@role, fa)), "#{@label}: the new edition took a row"
        assert has_element?(view, chip(@role, master, fa)), "the master kept the badges it had"
      end

      test "a site admin sees the same row and badges", ctx do
        site =
          create_site!(name: "Tenant #{ctx.n}", host: "tenant-#{ctx.n}.localhost", active: true)

        remember(site)
        %{master: master, fa: fa} = group(Map.put(ctx, :site, site), @resource)

        admin =
          create_user_with_permissions!(["*"],
            email: "tenant-groups-#{ctx.n}@example.com",
            site_id: site.id
          )

        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, site.host)
          |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
          |> Plug.Test.init_test_session(%{})
          |> AshAuthentication.Plug.Helpers.store_in_session(admin)

        view = open(conn, @path)

        assert has_element?(view, card(@role, master))
        refute has_element?(view, card(@role, fa))
        assert has_element?(view, chip(@role, master, fa))
      end
    end
  end

  describe "the shown edition's own actions" do
    test "Delete on a found translation archives that translation and leaves the master", ctx do
      %{master: master, fa: fa} = group(ctx, BlogPost)
      view = open(ctx.conn, "/admin/dashboard/blog/posts")

      search(view, BlogPost, fa.title)
      view |> element(~s(#{card("bp-row", fa)} button[phx-click="delete"])) |> render_click()
      render_async(view, @await)

      assert archived?(fa)
      refute archived?(master)
    end
  end

  # The master, its Persian edition and its Arabic one: one language group.
  defp group(%{site: site, n: n}, resource) do
    master = make(resource, site, n, "master", language: "en")

    edition = fn language ->
      make(resource, site, n, language,
        language: language,
        language_group_id: master.id
      )
    end

    %{master: master, fa: edition.("fa"), ar: edition.("ar")}
  end

  defp make(resource, site, n, name, overrides \\ [])

  defp make(BlogPost, site, n, name, overrides) do
    create_blog_post!(
      [site_id: site.id, status: :published, title: "Post #{name} #{n}"] ++ overrides
    )
  end

  defp make(Collection, site, n, name, overrides) do
    create_collection!([site_id: site.id, name: "Collection #{name} #{n}"] ++ overrides)
  end

  defp make(Tag, site, n, name, overrides) do
    create_blog_tag!([site_id: site.id, name: "Tag #{name} #{n}"] ++ overrides)
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  # A CHANGE REACHES THE TABLE AS A BROADCAST THE PAGE HANDS ON WITH `send_update/3`, which the page
  # runs after the render that delivered the broadcast — so it is the second render that shows it.
  # A BADGE OPENS ITS EDITION IN TWO TASKS: the page reads the edition, and the form that then draws
  # reads its record. `render_async/2` awaits only the tasks running when it is called, so the first
  # await ends with the form still loading — on a slow machine, every time.
  defp open_edition(view, badge) do
    view |> element(badge) |> render_click()
    render_async(view, @await)
    render_async(view, @await)
    view
  end

  defp settle(view) do
    render(view)
    render_async(view, @await)
    view
  end

  defp search(view, resource, term) do
    view
    |> form(filter_form(resource), %{"search" => term})
    |> render_change()

    render_async(view, @await)
    view
  end

  defp filter_form(BlogPost), do: "#posts-table_posts-filter"
  defp filter_form(Collection), do: "#collections-table_collections-filter"
  defp filter_form(Tag), do: "#tags-table_tags-filter"

  defp card(role, record), do: ~s([data-role="#{role}"][id$="#{record.id}"])

  defp chip(role, record, edition),
    do: ~s(#{card(role, record)} button[phx-value-id="#{edition.id}"])

  # A record the group column of which was never filled in, as one made before groups existed.
  defp ungroup!(table, record) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE #{table} SET language_group_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(record.id)]
    )
  end

  defp archived?(record) do
    match?(
      {:ok, %{archived_at: %DateTime{}}},
      Ash.get(record.__struct__, record.id, action: :master_get_archived, authorize?: false)
    )
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
