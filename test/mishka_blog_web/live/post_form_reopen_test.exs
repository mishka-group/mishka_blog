# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.PostFormReopenTest do
  @moduledoc """
  The posts page keeps its form mounted in `blog-post-form-modal` and only hides it, so a close that
  sends the form nothing — the modal's close icon, Escape, a click outside it — leaves what was typed
  in it. Opening the form again starts it over: Add Post (`#add-post-btn`) on the empty create form,
  a row's Edit on the post read again.

  A close is therefore nothing at all here: each case types into the form, sends nothing, and opens
  the form again the way the page does.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @posts "/admin/dashboard/blog/posts"
  @await 5_000
  @form "#post_form-form"
  @title "#post_form-form_title"
  @content "#post_form-form_content-editor-value"
  @surface "#post_form-form_content-editor-surface"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Reopen #{n}", host: "reopen-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)

    {:ok,
     conn: conn,
     n: n,
     site: site,
     post: create_blog_post!(site_id: site.id, title: "Saved #{n}", content: "<p>Saved body</p>"),
     admin:
       create_user_with_permissions!(["*"], email: "reopen-#{n}@example.com", site_id: site.id)}
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

  defp add_post(view) do
    html = view |> element("#add-post-btn") |> render_click()
    render_async(view, @await)
    {view, html}
  end

  defp edit_post(view, post) do
    view
    |> element(~s([phx-click*="#{post.id}"][phx-click*='"event":"edit"']))
    |> render_click()

    render_async(view, @await)
    assert has_element?(view, "#{@form}[method=put]")
    view
  end

  defp type(view, params) do
    field = params |> Map.keys() |> List.first()

    view
    |> form(@form, %{"form" => params})
    |> render_change(%{"_target" => ["form", field]})

    render_async(view, @await)
    view
  end

  defp value(view, selector) do
    node = view |> element(selector) |> render() |> LazyHTML.from_fragment()

    case LazyHTML.attribute(node, "value") do
      [value] -> value
      [] -> node |> LazyHTML.text() |> String.trim()
    end
  end

  defp editor_value(view) do
    view
    |> element(@surface)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-value")
  end

  defp field_errors?(view), do: has_element?(view, "#{@form} .hero-exclamation-circle")

  defp assert_empty_create(view) do
    assert has_element?(view, "#{@form}[method=post]")
    assert value(view, @title) == ""
    assert value(view, @content) == ""
    assert editor_value(view) in [[], [""]]
    refute field_errors?(view)
  end

  test "Add Post after a create closed without saving opens the empty create form", ctx do
    {view, _html} = ctx |> open_posts() |> add_post()

    type(view, %{"title" => "Half typed #{ctx.n}"})
    type(view, %{"content" => "<p>Half written</p>"})

    assert value(view, @title) == "Half typed #{ctx.n}"
    assert value(view, @content) == "<p>Half written</p>"

    {view, _html} = add_post(view)

    assert_empty_create(view)
  end

  test "Add Post draws the form anew, so the content editor reads the empty value", ctx do
    {view, _html} = ctx |> open_posts() |> add_post()

    type(view, %{"content" => "<p>Half written</p>"})
    assert editor_value(view) == ["<p>Half written</p>"]

    {view, html} = add_post(view)

    assert html |> LazyHTML.from_document() |> LazyHTML.query(@surface) |> Enum.count() == 0
    assert editor_value(view) in [[], [""]]
  end

  test "Add Post after a failed Create drops the typed values and the errors", ctx do
    {view, _html} = ctx |> open_posts() |> add_post()

    type(view, %{"title" => "Missing the rest #{ctx.n}"})
    refute field_errors?(view)

    view |> form(@form) |> render_submit()
    render_async(view, @await)

    assert field_errors?(view)

    {view, _html} = add_post(view)

    assert_empty_create(view)
  end

  test "Add Post after an edit closed without saving opens the empty create form", ctx do
    view = ctx |> open_posts() |> edit_post(ctx.post)

    type(view, %{"title" => "Unsaved #{ctx.n}"})

    {view, _html} = add_post(view)

    assert_empty_create(view)
  end

  test "Edit after a create closed without saving opens the post", ctx do
    {view, _html} = ctx |> open_posts() |> add_post()

    type(view, %{"title" => "Half typed #{ctx.n}"})
    edit_post(view, ctx.post)

    assert value(view, @title) == "Saved #{ctx.n}"
    assert value(view, @content) =~ "Saved body"
  end

  test "Edit on the post it was closed on reads the post again", ctx do
    view = ctx |> open_posts() |> edit_post(ctx.post)

    type(view, %{"title" => "Unsaved #{ctx.n}"})
    assert value(view, @title) == "Unsaved #{ctx.n}"

    edit_post(view, ctx.post)

    assert value(view, @title) == "Saved #{ctx.n}"
  end
end
