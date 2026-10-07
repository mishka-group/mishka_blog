defmodule MishkaBlogWeb.Test.PostContentComponentsTest do
  @moduledoc """
  "Insert component" in the post form: an author finds a component the post's site may draw, fills
  what it declares, and its marker lands in the content — through the form's own change, so nothing
  is saved until the author saves. See
  `MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`.

  The picker's fields belong to a form drawn after the post's form, so typing in them never reaches
  the post's change and Enter never saves the post; these tests drive that form as a browser would.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @posts "/admin/dashboard/blog/posts"
  @await 5_000
  @picker "#post_form-content-components"
  @owner "#post_form-content-components-form"
  @content "#post_form-form textarea[name='form[content]']"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Pieces #{n}", host: "pieces-#{n}.localhost", active: true)
    other = create_site!(name: "Others #{n}", host: "others-#{n}.localhost", active: true)
    Enum.each([home, site, other], &remember/1)

    callout = callout!(site, "callout-#{n}")
    shared = callout!(nil, "shared-#{n}")
    theirs = callout!(other, "theirs-#{n}")

    {:ok,
     conn: conn,
     n: n,
     site: site,
     callout: callout,
     shared: shared,
     theirs: theirs,
     admin:
       create_user_with_permissions!(["*"], email: "pieces-#{n}@example.com", site_id: site.id)}
  end

  defp callout!(site, name) do
    create_component!(
      name: name,
      site_id: site && site.id,
      active: true,
      description: "A boxed note",
      template:
        ~S|<aside data-title={@title} data-tone={@tone}>{render_slot(@inner_block)}</aside>|,
      attrs: [
        %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
        %{
          "name" => "tone",
          "type" => "string",
          "opts" => %{"default" => "info", "values" => ["info", "warn"]}
        },
        %{"name" => "rest", "type" => "global", "opts" => %{}}
      ],
      slots: [%{"name" => "inner_block", "opts" => %{}}]
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

  defp open_picker(view) do
    view |> element("#{@picker}-open") |> render_click()
    render_async(view, @await)
    view
  end

  defp content(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@content)
    |> LazyHTML.text()
  end

  test "offers the site's own components and the shared ones", ctx do
    view = ctx |> open_posts() |> open_picker()

    assert has_element?(view, "#{@picker}-pick-#{ctx.callout.name}")
    assert has_element?(view, "#{@picker}-pick-#{ctx.shared.name}")
    refute has_element?(view, "#{@picker}-pick-#{ctx.theirs.name}")
  end

  test "searching narrows the list", ctx do
    view = ctx |> open_posts() |> open_picker()

    view |> form(@owner, %{content_component: %{q: "shared"}}) |> render_change()

    assert has_element?(view, "#{@picker}-pick-#{ctx.shared.name}")
    refute has_element?(view, "#{@picker}-pick-#{ctx.callout.name}")
  end

  test "inserts the marker of the component picked, after what the author wrote", ctx do
    view = ctx |> open_posts()

    view
    |> form("#post_form-form", %{form: %{content: "<p>Intro</p>"}})
    |> render_change(%{"_target" => ["form", "content"]})

    open_picker(view)
    view |> element("#{@picker}-pick-#{ctx.callout.name}") |> render_click()

    assert has_element?(view, "#{@picker}-attr-title")
    assert has_element?(view, "#{@picker}-attr-tone option[value=warn]")
    assert has_element?(view, "#{@picker}-inner")
    refute has_element?(view, "#{@picker}-attr-rest")

    attrs = %{title: "Heads up", tone: "warn"}

    view
    |> form(@owner, %{content_component: %{attrs: attrs, inner: "Read <b>this</b>"}})
    |> render_change()

    marker =
      ~s([[component #{ctx.callout.name} title="Heads up" tone="warn"]]Read <b>this</b>[[/component]])

    assert view |> element("#{@picker}-marker") |> render() =~
             Phoenix.HTML.html_escape(marker) |> Phoenix.HTML.safe_to_string()

    view |> form(@owner) |> render_submit()

    assert content(view) == "<p>Intro</p>\n" <> marker
    refute has_element?(view, "#{@picker}-panel")
  end

  test "a component with nothing filled in is written self-closing", ctx do
    view = ctx |> open_posts() |> open_picker()

    view |> element("#{@picker}-pick-#{ctx.shared.name}") |> render_click()
    view |> form(@owner) |> render_submit()

    assert content(view) == "[[component #{ctx.shared.name} /]]"
  end

  test "pressing Enter in the search saves nothing and inserts nothing", ctx do
    view = ctx |> open_posts() |> open_picker()

    view |> form(@owner, %{content_component: %{q: "callout"}}) |> render_submit()

    assert content(view) == ""
    assert has_element?(view, "#{@picker}-panel")
  end
end
