# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.DashboardTest do
  @moduledoc """
  Mounts this extension's admin dashboard as a logged-in master admin — the page-level guard a
  compile cannot give: it renders the real LiveView (dead + connected), so a runtime crash in the
  calendar helper or a broken assign surfaces here.

  The page loads its figures in a `start_async/3`, so the assertions run against `render_async/1`:
  asserting on the first render would only ever see the em-dash placeholders and would pass even if
  every query raised.

  On the Comments page, a field a Reply fills and locks is locked only while adding: an edit opened
  after a Reply leaves the comment's parent changeable, and so does every blog form.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaGervaz.Form.Web.State
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

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

    # THIS SITE HAS THE BLOG. Everything below is about the dashboard, and a site that has never been
    # set up opens on the installer instead — which is the right answer there and the wrong fixture
    # here. `MishkaBlogWeb.Test.ProvisionButtonTest` is where the installer screen is driven.
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_blog, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn}
  end

  test "every blog page says it is powered by Mishka Blog, linking to the blog's own page", %{
    conn: conn
  } do
    conn = log_in(conn, create_admin("blogcredit@example.com"))

    for path <- ["/admin/dashboard/blog", "/admin/dashboard/blog/tags"] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "#admin-footer a[href='https://mishka.tools/cms/extensions/blog'][rel~='noopener']",
               "Mishka Blog"
             )

      footer = render(element(view, "#admin-footer"))
      assert footer =~ "© #{MishkaCmsCore.Layouts.copyright_years()}"
      assert footer =~ "Powered by"
    end
  end

  test "blog dashboard renders its real counts and toggles the editorial calendar", %{conn: conn} do
    conn = log_in(conn, create_admin("blogboss@example.com"))

    {:ok, view, html} = live(conn, "/admin/dashboard/blog")

    assert html =~ "MishkaBlog"
    assert html =~ "Comprehensive blog management system"
    assert has_element?(view, "#blog-new-post-btn")
    assert has_element?(view, "a[href$='/admin/dashboard/blog/collections']", "Collections")
    assert has_element?(view, "#blog-activity-toggle")

    # Explicit timeout rather than the 100ms default: this waits for the widgets to actually
    # finish, so the assertion below cannot fail merely because the machine was busy.
    loaded = render_async(view, 5_000)

    refute loaded =~ "Reading activity…"
    assert loaded =~ "Total Collections"
    assert loaded =~ "This Month"

    refute has_element?(view, "#blog-calendar")

    view |> element("#toggle-calendar-btn") |> render_click()

    assert has_element?(view, "#blog-calendar")
    assert render_async(view) =~ "Published and scheduled posts"
    assert has_element?(view, "#calendar-today-btn")
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

  defp click_row(view, comment, "reply"),
    do: click(view, ~s(button[phx-value-event="reply"][phx-value-values*="#{comment.id}"]))

  defp click_row(view, comment, "edit"),
    do: click(view, ~s([phx-click*="#{comment.id}"][phx-click*='"event":"edit"']))

  defp click(view, selector) do
    view |> element(selector) |> render_click()
    render_async(view, 5_000)
  end

  # Drain the page's async loads before stopping it, or an in-flight Ash read raises on the way down
  # once the test's sandbox owner is gone.
  defp close(view) do
    # Wait for completion, not a fixed guess — the default 100ms is shorter than the dashboard's
    # widget loads take, and a half-drained view raises on the way down.
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  describe "the Comments page" do
    test "keeps a comment's parent changeable on an edit opened after a Reply", %{conn: conn} do
      conn = log_in(conn, create_admin("moderator@example.com"))
      post = create_blog_post!(site_id: master_site().id)
      answered = create_comment!(post_id: post.id)
      edited = create_comment!(post_id: post.id)
      form = FormInfo.component_id(MishkaBlog.Comment)
      parent = "#search-select-#{form}-parent_comment_id input[name=_search_parent_comment_id]"

      {:ok, view, _html} = live(conn, "/admin/dashboard/blog/comments")
      render_async(view, 5_000)

      click_row(view, answered, "reply")

      assert has_element?(view, parent <> "[disabled]")

      click_row(view, edited, "edit")

      assert has_element?(view, "##{form}-form[method=put]")
      assert has_element?(view, parent)
      refute has_element?(view, parent <> "[disabled]")

      close(view)
    end

    test "a field the page's defaults lock is locked only while adding, on every blog form" do
      master = %{id: Ash.UUID.generate(), site_id: nil}

      locks =
        for resource <- Ash.Domain.Info.resources(MishkaBlog),
            field <- FormInfo.fields(resource),
            is_function(field.readonly, 1),
            Map.get(field, :show_on) != :create,
            do: {resource, field}

      assert locks != []

      for {resource, field} <- locks do
        editing =
          resource
          |> FormInfo.component_id()
          |> State.init(resource, master)
          |> State.update(mode: :update)

        given = State.update(editing, defaults: %{field.name => Ash.UUID.generate()})

        assert field.readonly.(given) == field.readonly.(editing),
               "#{inspect(resource)}'s #{field.name} is locked on edit by the page's defaults"
      end
    end
  end

  describe "PageGuard, through a real mount" do
    @moderator ["admin:dashboard:blog:comment"]
    @editor ["admin:dashboard:blog:post"]

    test "a moderator opens Comments but is refused Posts and Analytics", %{conn: conn} do
      moderator = create_user_with_permissions!(@moderator)

      assert {:ok, view, _html} =
               conn |> log_in(moderator) |> live("/admin/dashboard/blog/comments")

      close(view)

      for page <- ["/admin/dashboard/blog/posts", "/admin/dashboard/blog/analytics"] do
        assert {:error, {:redirect, %{flash: flash}}} = conn |> log_in(moderator) |> live(page)
        assert flash["error"] =~ "permission"
      end
    end

    test "an editor opens Posts and Analytics but is refused Comments", %{conn: conn} do
      editor = create_user_with_permissions!(@editor)

      for page <- ["/admin/dashboard/blog/posts", "/admin/dashboard/blog/analytics"] do
        assert {:ok, view, _html} = conn |> log_in(editor) |> live(page)
        close(view)
      end

      assert {:error, {:redirect, %{flash: flash}}} =
               conn |> log_in(editor) |> live("/admin/dashboard/blog/comments")

      assert flash["error"] =~ "permission"
    end

    test "an admin of neither area is refused the blog", %{conn: conn} do
      outsider = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      assert {:error, {:redirect, _to}} =
               conn |> log_in(outsider) |> live("/admin/dashboard/blog")
    end

    test "both open the blog's Home, since either area earns the section", %{conn: conn} do
      for names <- [@moderator, @editor] do
        user = create_user_with_permissions!(names)

        assert {:ok, view, _html} = conn |> log_in(user) |> live("/admin/dashboard/blog")
        assert has_element?(view, "[data-role=blog-head]")
        close(view)
      end
    end
  end

  # WHAT A NARROW ADMIN'S TABLE HOLDS once it has loaded, not only that its page opens: every row
  # preloads the site it belongs to, and a preload the admin is refused empties the whole list
  # behind a page that mounted.
  describe "a table, loaded for an admin of its area alone" do
    for {kind, path, names} <- [
          {:post, "/admin/dashboard/blog/posts", @editor},
          {:collection, "/admin/dashboard/blog/collections", @editor},
          {:tag, "/admin/dashboard/blog/tags", @editor},
          {:blogger, "/admin/dashboard/blog/bloggers", @editor},
          {:team, "/admin/dashboard/blog/teams", @editor},
          {:auto_posting, "/admin/dashboard/blog/auto-posting", @editor},
          {:comment, "/admin/dashboard/blog/comments", @moderator}
        ],
        {who, master?} <- [{"a master", true}, {"a site admin", false}] do
      @kind kind
      @path path
      @names names
      @master? master?

      test "#{who} holding only #{hd(names)} is shown the #{kind} row on #{path}", %{conn: conn} do
        site = master_site()
        record = make(@kind, site)

        user =
          create_user_with_permissions!(@names, site_id: if(@master?, do: nil, else: site.id))

        {:ok, view, _html} = conn |> log_in(user) |> live(@path)
        render_async(view, 5_000)

        assert has_element?(view, ~s([id$="#{record.id}"])),
               "the #{@kind} row is missing from #{@path}"

        close(view)
      end
    end

    test "an editor's Logs list the posts' history", %{conn: conn} do
      site = master_site()
      post = create_blog_post!(site_id: site.id)
      editor = create_user_with_permissions!(@editor)

      {:ok, view, _html} = conn |> log_in(editor) |> live("/admin/dashboard/blog")
      render_async(view, 5_000)

      view |> element("#blog-activity-toggle") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#blog-activity-list [id^=activity-]", post.title)

      close(view)
    end
  end

  defp make(:post, site), do: create_blog_post!(site_id: site.id)
  defp make(:collection, site), do: create_collection!(site_id: site.id)
  defp make(:tag, site), do: create_blog_tag!(site_id: site.id)
  defp make(:blogger, site), do: create_blogger!(site_id: site.id)
  defp make(:team, site), do: create_team!(site_id: site.id)
  defp make(:auto_posting, site), do: create_auto_posting!(site_id: site.id)
  defp make(:comment, site), do: create_comment!(site_id: site.id)

  # WHAT EACH AREA IS SHOWN on the blog's Home and Analytics: a post holder the editorial side, a
  # comment holder the comments, and the engagement figures — comments over views — only both.
  describe "the blog's Home, by area" do
    @cards "[data-role=blog-cards] a"

    defp open_home(conn, names) do
      user = create_user_with_permissions!(names)
      {:ok, view, _html} = conn |> log_in(user) |> live("/admin/dashboard/blog")
      render_async(view, 5_000)
      view
    end

    test "a moderator is shown the comments and nothing of the posts", %{conn: conn} do
      view = open_home(conn, @moderator)

      assert has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/comments']")
      refute has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/posts']")
      refute has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/analytics']")
      refute has_element?(view, "#blog-new-post-btn")
      refute has_element?(view, "#blog-analytics-btn")
      refute has_element?(view, "#blog-activity-toggle")
      refute has_element?(view, "#toggle-calendar-btn")

      assert has_element?(view, "[data-role=blog-kpis]", "New Comments")
      refute has_element?(view, "[data-role=blog-kpis]", "Today's Posts")
      refute has_element?(view, "[data-role=blog-kpis]", "Engagement")

      render_click(view, "toggle_calendar", %{})
      refute has_element?(view, "#blog-calendar")

      close(view)
    end

    test "an editor is shown the posts and nothing of the comments", %{conn: conn} do
      view = open_home(conn, @editor)

      assert has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/posts']")
      assert has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/analytics']")
      refute has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/comments']")
      assert has_element?(view, "#blog-new-post-btn")
      assert has_element?(view, "#blog-activity-toggle")
      assert has_element?(view, "#toggle-calendar-btn")

      assert has_element?(view, "[data-role=blog-kpis]", "Today's Posts")
      refute has_element?(view, "[data-role=blog-kpis]", "New Comments")
      refute has_element?(view, "[data-role=blog-kpis]", "Engagement")

      close(view)
    end

    test "a holder of both is shown the engagement figures", %{conn: conn} do
      view = open_home(conn, @editor ++ @moderator)

      assert has_element?(view, "[data-role=blog-kpis]", "Engagement")
      assert has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/comments']")
      assert has_element?(view, "#{@cards}[href$='/admin/dashboard/blog/posts']")

      close(view)
    end

    test "Analytics shows the engagement tile only to a holder of both", %{conn: conn} do
      for {names, shown?} <- [{@editor, false}, {@editor ++ @moderator, true}] do
        user = create_user_with_permissions!(names)
        {:ok, view, _html} = conn |> log_in(user) |> live("/admin/dashboard/blog/analytics")

        assert render_async(view, 5_000) =~ "Unique Readers"
        assert render(view) =~ "Engagement" == shown?, inspect(names)

        close(view)
      end
    end
  end
end
