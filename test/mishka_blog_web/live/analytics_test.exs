# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.AnalyticsTest do
  @moduledoc """
  The analytics page keeps its period, filters, comparison and sort in the URL, draws every panel
  once its read lands, and shows comment figures only to a holder of the comment area.
  """
  use MishkaBlog.ConnCase

  import MishkaBlog.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.States.SiteState

  @await 5_000
  @page "/admin/dashboard/blog/analytics"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Analytics #{n}", host: "analytics-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_blog, "test")

    post = create_blog_post!(site_id: site.id, status: :published, title: "Counted post")
    create_post_views!(post: post, views: 4)
    news = create_collection!(site_id: site.id, name: "News")
    create_post_collection!(post_id: post.id, collection_id: news.id)
    create_comment!(site_id: site.id, post_id: post.id, guest_name: "Grace")

    {:ok,
     conn: conn,
     site: site,
     news: news,
     admin:
       create_user_with_permissions!(["*"], email: "analytics-#{n}@example.com", site_id: site.id),
     editor:
       create_user_with_permissions!(["admin:dashboard:blog:post"],
         email: "analytics-editor-#{n}@example.com",
         site_id: site.id
       )}
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

  defp open(ctx, path, user) do
    host = ctx.site.host

    {:ok, view, _html} =
      ctx.conn
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(path)

    render_async(view, @await)
    view
  end

  test "every panel draws its figures once its read lands", ctx do
    view = open(ctx, @page, ctx.admin)

    assert has_element?(view, "[data-role=analytics-top-categories]", "News")
    assert has_element?(view, "[data-role=analytics-bottom]", "Counted post")
    assert has_element?(view, "[data-role=analytics-top-commenters]", "Grace")
    assert has_element?(view, "[data-role=analytics-chart-categories] svg")
    assert has_element?(view, "[data-role=analytics-chart-publishing]")

    assert has_element?(
             view,
             "#analytics-comments-pending[href*='comments_filter_status=pending']",
             "1"
           )

    assert has_element?(view, "[data-role=analytics-weekdays]")
  end

  test "a filter and the comparison go into the URL and survive a reload", ctx do
    view = open(ctx, @page, ctx.admin)

    view |> element("#analytics-filter-category") |> render_focus()
    render_async(view, @await)

    view
    |> element("#analytics-filter-category")
    |> render_keyup(%{"filter" => "category", "value" => "New"})

    render_async(view, @await)

    view
    |> element("[phx-click=relation_select][phx-value-id='#{ctx.news.id}']")
    |> render_click()

    assert assert_patch(view) =~ "category=#{ctx.news.id}"

    view |> element("#analytics-compare-form") |> render_change(%{"compare" => "true"})
    path = assert_patch(view)
    assert path =~ "category=#{ctx.news.id}"
    assert path =~ "compare=true"

    reloaded = open(ctx, path, ctx.admin)

    assert has_element?(reloaded, "#analytics-filter-category[value='News']")
    assert has_element?(reloaded, "input[name='filters[category]'][value='#{ctx.news.id}']")

    assert has_element?(reloaded, "#analytics-compare[checked]")
    assert has_element?(reloaded, "[data-role=previous-line]")
  end

  test "a Comments tile opens the list on the period's comments of its status", ctx do
    view = open(ctx, "#{@page}?days=7", ctx.admin)
    from = Date.utc_today() |> Date.add(-6) |> Date.to_iso8601()
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    assert has_element?(
             view,
             "#analytics-comments-pending[href*='comments_filter_written=#{from}~#{tomorrow}']",
             "1"
           )

    list =
      open(
        ctx,
        "/admin/dashboard/blog/comments?comments_filter_written=#{from}~#{tomorrow}",
        ctx.admin
      )

    assert has_element?(list, "[id$=-author]", "Grace")

    later = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

    none =
      open(
        ctx,
        "/admin/dashboard/blog/comments?comments_filter_written=#{tomorrow}~#{later}",
        ctx.admin
      )

    refute has_element?(none, "[id$=-author]", "Grace")
  end

  test "a filter's Clear takes it out of the URL", ctx do
    view = open(ctx, "#{@page}?category=#{ctx.news.id}", ctx.admin)

    view |> element("#analytics-clear-category") |> render_click()
    refute assert_patch(view) =~ "category="
  end

  test "a filter with no posts leaves the panels empty", ctx do
    other = create_collection!(site_id: ctx.site.id, name: "Empty")
    view = open(ctx, "#{@page}?category=#{other.id}", ctx.admin)

    refute has_element?(view, "[data-role=analytics-bottom]", "Counted post")
    assert has_element?(view, "[data-role=analytics-bottom]", "No post was opened")
    assert has_element?(view, "[data-role=analytics-quiet]", "No published post matches")
    assert has_element?(view, "[data-role=analytics-weekdays]", "No views recorded")
  end

  test "the period and the sort are patch links", ctx do
    view = open(ctx, "#{@page}?days=7", ctx.admin)

    view |> element("#analytics-sort-change") |> render_click()
    assert assert_patch(view) =~ "sort=change"
    assert has_element?(view, "#analytics-sort-change[aria-sort=descending]")

    view |> element("#analytics-range-90") |> render_click()
    assert assert_patch(view) =~ "days=90"
  end

  test "an editor without the comment area sees no comment figure", ctx do
    view = open(ctx, @page, ctx.editor)

    assert has_element?(view, "[data-role=analytics-bottom]", "Counted post")
    refute has_element?(view, "[data-role=analytics-top-commenters]")
    refute has_element?(view, "[data-role=analytics-comment-status]")
    refute has_element?(view, "[data-role=analytics-comments]")
    refute has_element?(view, "#analytics-sort-comments")
    refute has_element?(view, "#analytics-sort-engagement")
    refute has_element?(view, "[data-role=analytics-kpis]", "Engagement")
  end
end
