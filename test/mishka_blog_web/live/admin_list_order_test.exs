# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.AdminListOrderTest do
  @moduledoc """
  The blog's card lists open newest first, and the card page's Sort by turns them around.

  A post is listed by the date its card shows (`listed_at`) — a scheduled post's due date, else when
  it was published, else when it was written — so the order is the order of the dates on the page.
  A comment is listed by when it came.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @await 5_000

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    site = create_site!(name: "Order #{n}", host: "order-#{n}.localhost", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    admin =
      create_user_with_permissions!(["*"], email: "order-#{n}@example.com", site_id: site.id)

    {:ok, conn: conn, site: site, admin: admin}
  end

  test "posts come newest first by the date each one shows, and Sort by turns them around",
       ctx do
    old = published!(ctx.site, "Older", ~U[2025-01-10 10:00:00Z])
    mid = published!(ctx.site, "Middle", ~U[2026-02-10 10:00:00Z])
    draft = create_blog_post!(site_id: ctx.site.id, title: "Written today", status: :draft)

    view = open(ctx, "/admin/dashboard/blog/posts")

    assert rows(view, "posts") == Enum.map([draft, mid, old], & &1.id)
    assert has_element?(view, "#posts-table-sort-column option[value=site_datetime][selected]")
    assert has_element?(view, "#posts-table-sort-order[data-order=desc]")

    view |> element("#posts-table-sort-order") |> render_click()
    render_async(view, @await)

    assert rows(view, "posts") == Enum.map([old, mid, draft], & &1.id)
    assert has_element?(view, "#posts-table-sort-order[data-order=asc]")
  end

  test "Sort by takes another sortable column", ctx do
    draft = create_blog_post!(site_id: ctx.site.id, title: "A draft", status: :draft)
    out = published!(ctx.site, "Out", ~U[2026-02-10 10:00:00Z])

    view = open(ctx, "/admin/dashboard/blog/posts")
    assert rows(view, "posts") == [draft.id, out.id]

    view
    |> form("#posts-table-sort", %{"column" => "status", "order" => "desc"})
    |> render_change()

    render_async(view, @await)

    assert has_element?(view, "#posts-table-sort-column option[value=status][selected]")
    assert rows(view, "posts") == [out.id, draft.id]
  end

  test "comments come newest first", ctx do
    post = create_blog_post!(site_id: ctx.site.id)
    first = create_comment!(site_id: ctx.site.id, post_id: post.id, content: "First")
    second = create_comment!(site_id: ctx.site.id, post_id: post.id, content: "Second")

    view = open(ctx, "/admin/dashboard/blog/comments")

    assert rows(view, "comments") == [second.id, first.id]
    assert has_element?(view, "#comments-table-sort-column option[value=inserted_at][selected]")
  end

  defp published!(site, title, at) do
    site_id = site.id

    [site_id: site_id, title: title, status: :published]
    |> create_blog_post!()
    |> Ash.Seed.update!(%{published_at: at})
  end

  # The records' ids in the order the list draws them.
  defp rows(view, stream) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=bp-row]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace(&1, ~r/^.*#{stream}-/, ""))
  end

  defp open(ctx, path) do
    {:ok, view, _html} =
      ctx.conn
      |> Map.put(:host, ctx.site.host)
      |> Map.update!(:req_headers, &[{"host", ctx.site.host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(ctx.admin)
      |> live(path)

    render_async(view, @await)
    view
  end
end
