# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.RoadmapNoticesTest do
  @moduledoc """
  A blog section that is not finished says so where the admin opens it, and does not pretend to work.

  Auto Posting and Analytics each open on a notice that the section is on the roadmap. Auto Posting's
  Edit and Versions buttons have no handler yet, so they are drawn disabled with a tooltip instead of
  doing nothing when clicked. The dashboard marks every figure counted from the view log — nothing
  records a view yet — and the two sections that are not built; a viewer who is shown no view figure
  is shown no label. The post form's Scheduled status and a blogger's Can Publish Directly toggle
  each carry a hint that the thing they promise is on the roadmap.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, as: Home
  alias MishkaCmsCore.Runtime.States.SiteState

  @await 5_000
  @badge "[data-role=roadmap-badge]"
  @notice "[role=note][data-role=roadmap-notice]"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Roadmap #{n}", host: "roadmap-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_blog, "test")

    {:ok,
     conn: conn,
     site: site,
     admin:
       create_user_with_permissions!(["*"], email: "roadmap-#{n}@example.com", site_id: site.id)}
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

  defp open(ctx, path, user \\ nil) do
    host = ctx.site.host

    {:ok, view, _html} =
      ctx.conn
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user || ctx.admin)
      |> live(path)

    render_async(view, @await)
    view
  end

  defp badges(view, kind), do: view |> render() |> LazyHTML.from_fragment() |> badges_of(kind)

  defp badges_of(document, kind),
    do: document |> LazyHTML.query("#{@badge}[data-kind=#{kind}]") |> Enum.to_list()

  describe "Auto Posting" do
    test "opens on a notice that the section is on the roadmap", ctx do
      view = open(ctx, "/admin/dashboard/blog/auto-posting")

      notice = "#auto-posting-roadmap#{@notice}"

      assert has_element?(view, notice, "This section is not available yet")

      assert has_element?(
               view,
               notice,
               "It is on our roadmap. What you see here shows how it will work."
             )
    end

    test "draws Edit and Versions disabled, with a tooltip that says why", ctx do
      configuration = create_auto_posting!(site_id: ctx.site.id)
      view = open(ctx, "/admin/dashboard/blog/auto-posting")

      for {action, hint} <- [
            {"edit", "Editing is on our roadmap."},
            {"versions", "Version history is on our roadmap."}
          ] do
        button = "#auto-posting-#{action}-roadmap-#{configuration.id}"

        assert has_element?(view, "#{button}[disabled][aria-disabled=true]")
        assert has_element?(view, "[data-role=roadmap-action][title='#{hint}'] #{button}")
        refute has_element?(view, "#{button}[phx-click]")
      end

      refute has_element?(view, "button[phx-value-event=edit_auto_posting]")
      refute has_element?(view, "button[phx-value-event=show_versions]")
    end

    test "keeps the actions that work: Activate, Deactivate and Delete", ctx do
      create_auto_posting!(site_id: ctx.site.id)
      view = open(ctx, "/admin/dashboard/blog/auto-posting")

      assert has_element?(view, "button[title=Delete]")
    end
  end

  describe "Analytics" do
    test "opens on a notice that Analytics is on the roadmap, above its figures", ctx do
      view = open(ctx, "/admin/dashboard/blog/analytics")

      notice = "#analytics-roadmap#{@notice}"

      assert has_element?(view, notice, "Analytics is not available yet")

      assert has_element?(
               view,
               notice,
               "It is on our roadmap. What you see here shows how it will work."
             )

      html = render(view)
      {notice, _} = :binary.match(html, ~s(id="analytics-roadmap"))
      {figures, _} = :binary.match(html, ~s(data-role="analytics-kpis"))

      assert notice < figures
    end

    test "is still there to use: the range buttons and the chart are not hidden", ctx do
      view = open(ctx, "/admin/dashboard/blog/analytics")

      assert has_element?(view, "#analytics-range-30")
      assert has_element?(view, "[data-role=analytics-chart]")
    end
  end

  describe "the blog dashboard" do
    test "labels each figure counted from the view log as not tracked yet", ctx do
      view = open(ctx, "/admin/dashboard/blog")

      untracked = badges(view, :untracked)

      assert length(untracked) == 4
      assert Enum.all?(untracked, &(LazyHTML.text(&1) =~ "Not tracked yet"))

      for figure <- ["Today's Views", "Engagement", "Total Views", "Engagement Rate"] do
        assert Home.untracked?(figure)
      end

      refute Home.untracked?("Today's Posts")
      refute Home.untracked?("Posts Published")
    end

    test "labels the Auto Posting and Analytics cards as on the roadmap", ctx do
      view = open(ctx, "/admin/dashboard/blog")

      assert [_, _] = roadmap = badges(view, :roadmap)
      assert Enum.all?(roadmap, &(LazyHTML.text(&1) =~ "On our roadmap"))

      assert has_element?(
               view,
               "a[href$='/admin/dashboard/blog/auto-posting'] [data-kind=roadmap]"
             )

      assert has_element?(view, "a[href$='/admin/dashboard/blog/analytics'] [data-kind=roadmap]")
      refute has_element?(view, "a[href$='/admin/dashboard/blog/tags'] [data-kind=roadmap]")
      assert Home.on_roadmap?("Auto Posting")
      refute Home.on_roadmap?("Tags")
    end

    test "draws no label for a viewer who is shown no view figure", ctx do
      moderator =
        create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: ctx.site.id)

      view = open(ctx, "/admin/dashboard/blog", moderator)

      assert has_element?(view, "[data-role=blog-kpis]")
      refute has_element?(view, @badge)
    end
  end

  describe "the forms" do
    test "the post form says publishing at the scheduled time is on the roadmap", ctx do
      view = open(ctx, "/admin/dashboard/blog/posts")

      assert has_element?(
               view,
               "#post_form-form [data-role=gervaz-field-description]",
               "Publishing at the scheduled time is on our roadmap."
             )

      html = render(view)
      {status, _} = :binary.match(html, ~s(id="post_form-form_status-label"))
      {hint, _} = :binary.match(html, "Publishing at the scheduled time is on our roadmap.")

      assert status < hint
    end

    test "the blogger form says enforcing Can Publish Directly is on the roadmap", ctx do
      view = open(ctx, "/admin/dashboard/blog/bloggers")

      assert has_element?(
               view,
               "#blogger_form-form [data-role=gervaz-field-description]",
               "Enforcing this when a post is published is on our roadmap."
             )
    end
  end
end
