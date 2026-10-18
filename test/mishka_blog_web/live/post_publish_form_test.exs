# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.PostPublishFormTest do
  @moduledoc """
  A site's admin publishes and schedules a post from the posts page's form: Published stamps the
  post with the time it went live, and Scheduled, which the form gives no time to, is refused on the
  scheduled time instead of saving a post that never goes live.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @posts "/admin/dashboard/blog/posts"
  @await 5_000
  @form "#post_form-form"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Publish #{n}", host: "publish-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)

    admin =
      create_user_with_permissions!(["*"], email: "publish-#{n}@example.com", site_id: site.id)

    {:ok, conn: conn, n: n, site: site, admin: admin}
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

  defp open_posts(%{conn: conn, admin: admin, site: site}) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, site.host)
      |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)
      |> live(@posts)

    render_async(view, @await)
    view
  end

  defp submit_new_post(ctx, status) do
    view = open_posts(ctx)
    view |> element("#add-post-btn") |> render_click()
    render_async(view, @await)

    view
    |> form(@form, %{
      "form" => %{
        "title" => "Publish #{ctx.n}",
        "slug" => "publish-#{ctx.n}",
        "content" => "<p>Body</p>",
        "language" => "en",
        "status" => status
      }
    })
    |> render_submit()

    render_async(view, @await)
    view
  end

  defp saved_post(ctx) do
    BlogPost
    |> Ash.Query.filter(slug == ^"publish-#{ctx.n}")
    |> Ash.read_one!(tenant: ctx.site.id, authorize?: false)
  end

  test "Add Post saved as Published stamps the time it went live", ctx do
    submit_new_post(ctx, "published")

    post = saved_post(ctx)

    assert post.status == :published
    assert %DateTime{} = post.published_at
    assert DateTime.diff(DateTime.utc_now(), post.published_at, :second) in 0..10
  end

  test "Add Post saved as Scheduled is refused for the scheduled time and saves nothing", ctx do
    view = submit_new_post(ctx, "scheduled")

    assert saved_post(ctx) == nil
    assert has_element?(view, "#{@form} .hero-exclamation-circle")
  end

  test "Add Post saved as Draft stays unpublished", ctx do
    submit_new_post(ctx, "draft")

    post = saved_post(ctx)

    assert post.status == :draft
    assert post.published_at == nil
  end

  test "Edit of a draft saved as Published stamps it, and a later save keeps the time", ctx do
    draft = create_blog_post!(site_id: ctx.site.id, status: :draft, slug: "publish-#{ctx.n}")
    view = open_posts(ctx)

    view
    |> element(~s([phx-click*="#{draft.id}"][phx-click*='"event":"edit"']))
    |> render_click()

    render_async(view, @await)

    view |> form(@form, %{"form" => %{"status" => "published"}}) |> render_submit()
    render_async(view, @await)

    published = saved_post(ctx)
    assert published.status == :published
    assert %DateTime{} = published.published_at

    view
    |> element(~s([phx-click*="#{draft.id}"][phx-click*='"event":"edit"']))
    |> render_click()

    render_async(view, @await)

    view |> form(@form, %{"form" => %{"title" => "Renamed #{ctx.n}"}}) |> render_submit()
    render_async(view, @await)

    saved_again = saved_post(ctx)
    assert saved_again.title == "Renamed #{ctx.n}"
    assert saved_again.published_at == published.published_at
  end
end
