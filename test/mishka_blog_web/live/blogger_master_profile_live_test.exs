# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.BloggerMasterProfileLiveTest do
  @moduledoc """
  A master's blogger profiles, as the admin pages show them.

  The blogger form's account picker offers a master the chosen site's users and every master, each
  master marked as one, and a master makes its own profile on a site there. A site's admin is
  offered its own site's users only — no master, however it searches — and a master's account put
  into the form by hand is refused in plain words.

  A site's admin sees a master's profile on its site like any other: in the bloggers list, and in
  the post form's author picker, by the profile's own name. The master's account reaches none of
  those pages, nor the profile's version history: not in what they render, and not in the rows they
  load. Another site's admin sees none of it.

  `MishkaBlog.BloggerMasterProfileTest` holds the same rules for the resources themselves.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.Blogger
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaGervaz.ResourceInfo

  require Ash.Query

  @await 5_000
  @bloggers "/admin/dashboard/blog/bloggers"
  @posts "/admin/dashboard/blog/posts"
  @site_field "#search-select-blogger_form-site_id"
  @user_field "#search-select-blogger_form-user_id"
  @authors_field "#multi-select-post_form-blogger_ids"
  @refused "That user is not one this site can use."
  @account_fields [:email, :confirmed_at, :site_id, :permission_values]

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site_a = create_site!(name: "Site A", host: "site-a.localhost", active: true)
    site_b = create_site!(name: "Site B", host: "site-b.localhost", active: true)
    Enum.each([home, site_a, site_b], &remember/1)

    master = create_user_with_permissions!(["*"], email: "the.master@example.com")
    profile = master_profile!(master, site_a, "Master On A")

    {:ok,
     conn: conn,
     home: home,
     site_a: site_a,
     site_b: site_b,
     master: master,
     profile: profile,
     other_master: create_user!(email: "other.master@example.com"),
     admin_a:
       create_user_with_permissions!(["*"], email: "admin.a@example.com", site_id: site_a.id),
     admin_b:
       create_user_with_permissions!(["*"], email: "admin.b@example.com", site_id: site_b.id),
     writer_a: create_user!(email: "writer.a@example.com", site_id: site_a.id),
     writer_b: create_user!(email: "writer.b@example.com", site_id: site_b.id)}
  end

  defp master_profile!(master, site, name) do
    Blogger
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        user_id: master.id,
        site_id: site.id,
        display_name: name,
        slug: slug(name),
        bio: "Writes for #{site.name}"
      },
      actor: master
    )
    |> Ash.create!()
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(" ", "-")

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

  defp signed_in(conn, user, host, opts \\ []) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> then(&if(opts[:master_mode], do: Plug.Conn.put_session(&1, :master_mode, true), else: &1))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp as_master(ctx), do: signed_in(ctx.conn, ctx.master, ctx.home.host, master_mode: true)
  defp as_admin_a(ctx), do: signed_in(ctx.conn, ctx.admin_a, ctx.site_a.host)
  defp as_admin_b(ctx), do: signed_in(ctx.conn, ctx.admin_b, ctx.site_b.host)

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  defp option(field, id), do: "#{field} button[phx-value-id='#{id}']"

  defp choose_site(view, site, field \\ @site_field) do
    view |> element("#{field} input[name='_search_site_id']") |> render_focus()
    view |> element(option(field, site.id)) |> render_click()
    render_async(view, @await)
  end

  defp open_accounts(view) do
    view |> element("#{@user_field} input[name='_search_user_id']") |> render_focus()
    view
  end

  defp search_accounts(view, term) do
    view
    |> element("#{@user_field} input[name='_search_user_id']")
    |> render_keyup(%{"_search_user_id" => term, "value" => term})

    view
  end

  defp open_authors(view) do
    view |> element("#{@authors_field} input[name='_search_blogger_ids']") |> render_focus()
    view
  end

  defp save_profile(view, name) do
    view
    |> form("#blogger_form-form", %{
      "form" => %{"display_name" => name, "slug" => slug(name)}
    })
    |> render_submit()
  end

  defp withheld?(%User{} = user),
    do: Enum.all?(@account_fields, &match?(%Ash.ForbiddenField{}, Map.get(user, &1)))

  defp withheld?(nil), do: true

  # The rows the bloggers list reads for a site's admin, with the table's own read and preloads.
  defp listed_as(admin, site, profile) do
    Blogger
    |> Ash.Query.for_read(ResourceInfo.table_action_for(Blogger, :read, false), %{},
      actor: admin,
      tenant: site.id
    )
    |> Ash.Query.filter(id == ^profile.id)
    |> Ash.Query.load(ResourceInfo.table_all_preloads(Blogger, false))
    |> Ash.read!(actor: admin, tenant: site.id, page: false)
  end

  defp profiles_of(user) do
    Blogger
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, page: false)
  end

  describe "the account picker's mark on a master" do
    test "reads in the admin's language" do
      display = MishkaGervaz.Resource.Info.Form.field(MishkaBlog.Blogger, :user_id).display_field
      master = %{site_id: nil, email: "the.master@example.com"}

      assert display.(master) == "the.master@example.com (master)"

      assert display.(%{site_id: Ash.UUID.generate(), email: "writer@example.com"}) ==
               "writer@example.com"

      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      assert display.(master) == "[fa] the.master@example.com (master)"
    end
  end

  describe "the blogger form's account picker, as a master" do
    test "offers the chosen site's users and every master, the masters marked", ctx do
      view = ctx |> as_master() |> open(@bloggers)
      choose_site(view, ctx.site_a)
      open_accounts(view)

      assert has_element?(view, option(@user_field, ctx.writer_a.id), "writer.a@example.com")
      assert has_element?(view, option(@user_field, ctx.admin_a.id), "admin.a@example.com")

      assert has_element?(
               view,
               option(@user_field, ctx.master.id),
               "the.master@example.com (master)"
             )

      assert has_element?(
               view,
               option(@user_field, ctx.other_master.id),
               "other.master@example.com (master)"
             )

      refute has_element?(view, option(@user_field, ctx.writer_a.id), "(master)")
      refute has_element?(view, option(@user_field, ctx.writer_b.id))
      refute has_element?(view, option(@user_field, ctx.admin_b.id))
    end

    test "makes its own profile on another site from the form", ctx do
      view = ctx |> as_master() |> open(@bloggers)
      choose_site(view, ctx.site_b)
      open_accounts(view)
      view |> element(option(@user_field, ctx.master.id)) |> render_click()

      save_profile(view, "Master On B")

      assert [on_a, on_b] = Enum.sort_by(profiles_of(ctx.master), & &1.display_name)
      assert {on_a.site_id, on_b.site_id} == {ctx.site_a.id, ctx.site_b.id}
      assert on_b.display_name == "Master On B"
    end
  end

  describe "the blogger form's account picker, as a site's admin" do
    test "offers its own site's users and no master", ctx do
      view = ctx |> as_admin_a() |> open(@bloggers) |> open_accounts()

      assert has_element?(view, option(@user_field, ctx.writer_a.id), "writer.a@example.com")
      refute has_element?(view, option(@user_field, ctx.master.id))
      refute has_element?(view, option(@user_field, ctx.other_master.id))
      refute has_element?(view, option(@user_field, ctx.writer_b.id))
      refute has_element?(view, "#{@user_field} button", "(master)")
    end

    test "finds no master however it searches", ctx do
      view = ctx |> as_admin_a() |> open(@bloggers) |> open_accounts()

      for term <- ["the.master", "master@example.com", "other.master"] do
        search_accounts(view, term)

        refute has_element?(view, option(@user_field, ctx.master.id)), term
        refute has_element?(view, option(@user_field, ctx.other_master.id)), term
      end

      search_accounts(view, "writer.a")
      assert has_element?(view, option(@user_field, ctx.writer_a.id))
    end

    test "a master's account put into the form by hand is refused in plain words", ctx do
      view = ctx |> as_admin_a() |> open(@bloggers) |> open_accounts()

      view
      |> element(option(@user_field, ctx.writer_a.id))
      |> render_click(%{"id" => ctx.other_master.id, "label" => "writer.a@example.com"})

      save_profile(view, "Not Theirs To Make")

      assert has_element?(view, "#blogger_form-form", @refused)
      assert profiles_of(ctx.other_master) == []
    end
  end

  describe "a master's profile on the site's pages, as the site's admin" do
    test "the bloggers list shows the profile, and neither shows nor loads the account", ctx do
      view = ctx |> as_admin_a() |> open(@bloggers)

      assert has_element?(view, "[data-role=blcard][id$='#{ctx.profile.id}']", "Master On A")
      refute render(view) =~ "the.master@example.com"

      assert [listed] = listed_as(ctx.admin_a, ctx.site_a, ctx.profile)
      assert listed.user_id == ctx.master.id
      assert withheld?(listed.user)
    end

    test "the post form offers it as an author by its name, never the account's email", ctx do
      view = ctx |> as_admin_a() |> open(@posts) |> open_authors()

      assert has_element?(view, option(@authors_field, ctx.profile.id), "Master On A")
      refute render(view) =~ "the.master@example.com"

      view |> element(option(@authors_field, ctx.profile.id)) |> render_click()

      assert has_element?(
               view,
               "#{@authors_field} input[type=hidden][value='#{ctx.profile.id}']"
             )
    end

    test "its version history names no master", ctx do
      Blogger
      |> Ash.get!(ctx.profile.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_update(:master_update, %{bio: "Edited by the master"},
        actor: ctx.master
      )
      |> Ash.update!()

      view = ctx |> as_admin_a() |> open(@bloggers)
      send(view.pid, {:row_action, "show_versions", %{"id" => ctx.profile.id}})
      render_async(view, @await)

      assert has_element?(view, "#blogger-versions-modal [phx-click=restore_version]")
      refute render(view) =~ "the.master@example.com"

      versions = :sys.get_state(view.pid).socket.assigns.versions
      assert Enum.count(versions, &(&1.user_id == ctx.master.id)) == 2
      assert Enum.all?(versions, &withheld?(&1.user))
    end

    test "the admin dashboard names the master by its profile, never by its account", ctx do
      post = create_blog_post!(site_id: ctx.site_a.id, status: :published, title: "On A")
      create_post_blogger!(post_id: post.id, blogger_id: ctx.profile.id)

      create_comment!(
        site_id: ctx.site_a.id,
        post_id: post.id,
        author_id: ctx.master.id,
        content: "A master's comment",
        status: :pending
      )

      view = ctx |> as_admin_a() |> open("/admin/dashboard")

      assert has_element?(view, "span", "Master On A")
      refute render(view) =~ "the.master"
    end

    test "a master still sees whose account it is in the post form", ctx do
      view = ctx |> as_master() |> open(@posts)
      choose_site(view, ctx.site_a, "#search-select-post_form-site_id")
      open_authors(view)

      assert has_element?(view, option(@authors_field, ctx.profile.id), "the.master@example.com")
    end
  end

  describe "a master's profile, as another site's admin" do
    test "is in neither its bloggers list nor its post form", ctx do
      view = ctx |> as_admin_b() |> open(@bloggers)
      refute has_element?(view, "[data-role=blcard][id$='#{ctx.profile.id}']")

      view = ctx |> as_admin_b() |> open(@posts) |> open_authors()
      refute has_element?(view, option(@authors_field, ctx.profile.id))
      refute render(view) =~ "the.master@example.com"
    end
  end
end
