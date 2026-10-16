# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.PostContentEditorTest do
  @moduledoc """
  A post's content is written in the content editor (`extra %{content_editor: true}` on the form's
  `content` field, drawn by `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1`): the form draws it,
  its palette offers the components the post's site may draw, and what the editor hands the form —
  HTML with each placed component's marker in a paragraph of its own — is saved as it always was,
  through the post's sanitizer, with the markers kept and named beside the content.

  The editor's own answers are core's `MishkaCmsCoreWeb.Test.ContentEditorTest`; the browser side
  is the CMS's `assets/js/content_editor.test.js`.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @posts "/admin/dashboard/blog/posts"
  @await 5_000
  @editor "post_form-form_content-editor"
  @components "#post_form-form_content-editor-components"

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Pieces #{n}", host: "pieces-#{n}.localhost", active: true)
    other = create_site!(name: "Others #{n}", host: "others-#{n}.localhost", active: true)
    Enum.each([home, site, other], &remember/1)

    {:ok,
     conn: conn,
     n: n,
     site: site,
     callout: callout!(site, "callout-#{n}"),
     shared: callout!(nil, "shared-#{n}"),
     theirs: callout!(other, "theirs-#{n}"),
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

  defp saved(site, slug) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(slug == ^slug and site_id == ^site.id)
    |> Ash.read_one!(authorize?: false)
  end

  test "the post form draws the content editor on its content field", ctx do
    view = open_posts(ctx)

    assert has_element?(
             view,
             "##{@editor}-surface[phx-hook=ContentEditor][phx-update=ignore][data-format=html]"
           )

    assert has_element?(view, "#post_form-form textarea##{@editor}-value[name='form[content]']")
    assert has_element?(view, "##{@editor} [data-part=toolbar] [data-editor-command=h2]")
    refute has_element?(view, "#post_form-content-components")
  end

  test "its palette offers the site's own components and the shared ones", ctx do
    view = open_posts(ctx)

    view |> element(@components <> "-toggle") |> render_click()

    # THE PALETTE HAS LOADED once the editor is told which of its components hold content. The same
    # click starts building the site's preview stylesheet — on a fresh VM three Tailwind runs, seconds
    # of them — which `render_async/2` would wait for as well, and which nothing here asserts on.
    assert_push_event(view, "mishka:content_editor", %{id: @editor, holders: _holders}, @await)

    assert has_element?(view, "#{@components}-pick-#{ctx.callout.name}")
    assert has_element?(view, "#{@components}-pick-#{ctx.shared.name}")
    refute has_element?(view, "#{@components}-pick-#{ctx.theirs.name}")
  end

  test "what the editor hands the form is saved sanitized, with its markers kept", ctx do
    view = open_posts(ctx)

    marker =
      ~s([[component #{ctx.callout.name} title="Heads up" tone="warn"]]Read <b>this</b>[[/component]])

    content =
      ~s|<p dir="auto">Intro</p><p>#{marker}</p><script>alert(1)</script>| <>
        ~s|<p dir="auto" onclick="steal()">After</p>|

    slug = "editor-post-#{ctx.n}"

    view
    |> form("#post_form-form", %{
      "form" => %{"title" => "Editor post", "slug" => slug, "status" => "draft"}
    })
    |> render_submit(%{"form" => %{"content" => content}})

    post = saved(ctx.site, slug)

    assert post.content =~ "<p>#{marker}</p>"
    assert post.content =~ ~s(<p dir="auto">Intro</p>)
    refute post.content =~ "<script"
    refute post.content =~ "onclick"
    assert post.content_components == [ctx.callout.name]
  end
end
