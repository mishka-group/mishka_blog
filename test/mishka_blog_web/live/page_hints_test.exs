# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.PageHintsTest do
  @moduledoc """
  The blog's admin pages say what works and draw no roadmap label: Analytics opens on its figures,
  the dashboard marks no section as on the roadmap, and the post form's Scheduled status and a
  blogger's Can Publish Directly toggle each say what they do.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.States.SiteState

  @await 5_000
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

  describe "the blog dashboard" do
    test "marks no section as on the roadmap", ctx do
      view = open(ctx, "/admin/dashboard/blog")

      assert has_element?(view, "a[href$='/admin/dashboard/blog/analytics']")
      refute has_element?(view, "[data-role=roadmap-badge]")
      refute has_element?(view, "a[href$='/admin/dashboard/blog/auto-posting']")
    end
  end

  describe "Analytics" do
    test "opens on its figures, with no roadmap notice", ctx do
      view = open(ctx, "/admin/dashboard/blog/analytics")

      refute has_element?(view, @notice)
      assert has_element?(view, "[data-role=analytics-kpis]", "Unique Readers")
    end

    test "is still there to use: the range buttons and the chart are not hidden", ctx do
      view = open(ctx, "/admin/dashboard/blog/analytics")

      assert has_element?(view, "#analytics-range-30")
      assert has_element?(view, "[data-role=analytics-chart]")
    end
  end

  describe "the forms" do
    test "the post form says a scheduled post is published at its time", ctx do
      view = open(ctx, "/admin/dashboard/blog/posts")

      assert has_element?(
               view,
               "#post_form-form [data-role=gervaz-field-description]",
               "A scheduled post is published at its time."
             )

      html = render(view)
      {status, _} = :binary.match(html, ~s(id="post_form-form_status-label"))
      {hint, _} = :binary.match(html, "A scheduled post is published at its time.")

      assert status < hint
    end

    test "the post form asks for the publish time only while the status is Scheduled", ctx do
      view = open(ctx, "/admin/dashboard/blog/posts")
      refute has_element?(view, "[id^=post_form-form_scheduled_publish_at]")

      view |> form("#post_form-form", form: %{status: "scheduled"}) |> render_change()
      assert has_element?(view, "[id^=post_form-form_scheduled_publish_at]")

      view |> form("#post_form-form", form: %{status: "draft"}) |> render_change()
      refute has_element?(view, "[id^=post_form-form_scheduled_publish_at]")
    end

    test "the blogger form says what Can Publish Directly does", ctx do
      view = open(ctx, "/admin/dashboard/blog/bloggers")

      assert has_element?(
               view,
               "#blogger_form-form [data-role=gervaz-field-description]",
               "Off: this blogger saves drafts, and an editor publishes them."
             )
    end
  end
end
