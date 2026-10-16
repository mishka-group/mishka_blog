# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.PostFormRelationsTest do
  @moduledoc """
  A post opened for editing keeps its collections, bloggers and tags on the form while another
  field changes, and a save keeps them.

  The three pickers are `:search_multi` relation fields of the post form (`post_form-form`), each
  posting its picks as hidden `<field>[]` inputs beside the form's own params. Each case opens the
  post from the posts page, changes the title through the form's `phx-change`, and checks the
  rendered pickers and what reaches the post.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @posts "/admin/dashboard/blog/posts"
  @await 5_000
  @form "#post_form-form"
  @pickers [:collection_ids, :blogger_ids, :tag_ids]

  setup %{conn: conn} do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site = create_site!(name: "Relations #{n}", host: "relations-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)

    post = create_blog_post!(site_id: site.id, title: "Kept #{n}")
    collections = for i <- 1..2, do: create_collection!(site_id: site.id, name: "Col #{n}-#{i}")
    tags = for i <- 1..2, do: create_blog_tag!(site_id: site.id, name: "Tag #{n}-#{i}")
    bloggers = for _ <- 1..2, do: create_blogger!(site_id: site.id)

    Enum.each(collections, &create_post_collection!(post_id: post.id, collection_id: &1.id))
    Enum.each(tags, &create_post_tag!(post_id: post.id, tag_id: &1.id))
    Enum.each(bloggers, &create_post_blogger!(post_id: post.id, blogger_id: &1.id))

    {:ok,
     conn: conn,
     n: n,
     site: site,
     post: post,
     extra_tag: create_blog_tag!(site_id: site.id, name: "Tag #{n}-new"),
     held: %{
       collection_ids: ids(collections),
       blogger_ids: ids(bloggers),
       tag_ids: ids(tags)
     },
     admin:
       create_user_with_permissions!(["*"], email: "relations-#{n}@example.com", site_id: site.id)}
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

  defp ids(records), do: records |> Enum.map(&to_string(&1.id)) |> Enum.sort()

  defp edit_post(%{conn: conn, admin: admin, site: site, post: post}) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, site.host)
      |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)
      |> live(@posts)

    render_async(view, @await)

    view
    |> element(~s([phx-click*="#{post.id}"][phx-click*='"event":"edit"']))
    |> render_click()

    render_async(view, @await)
    assert has_element?(view, "#{@form}[method=put]")
    view
  end

  defp change_title(view, title) do
    view
    |> form(@form, %{"form" => %{"title" => title}})
    |> render_change(%{"_target" => ["form", "title"]})

    render_async(view, @await)
    view
  end

  defp shown(view) do
    html = view |> element(@form) |> render()

    Map.new(@pickers, fn field ->
      held =
        ~r/<input type="hidden" name="#{field}\[\]" value="([^"]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      {field, held}
    end)
  end

  defp saved(%{post: post, admin: admin, site: site}) do
    Ash.get!(MishkaBlog.BlogPost, post.id,
      actor: admin,
      tenant: site.id,
      load: [:tenant_collections, :tenant_bloggers, :tenant_tags]
    )
  end

  defp relations(post) do
    %{
      collection_ids: ids(post.tenant_collections),
      blogger_ids: ids(post.tenant_bloggers),
      tag_ids: ids(post.tenant_tags)
    }
  end

  test "the form opens with the post's collections, bloggers and tags", ctx do
    assert ctx |> saved() |> relations() == ctx.held
    assert ctx |> edit_post() |> shown() == ctx.held
  end

  test "a change to the title keeps every picker's selection on the form", ctx do
    view = ctx |> edit_post() |> change_title("Renamed #{ctx.n}")

    assert shown(view) == ctx.held
  end

  test "a save after that change keeps the post's collections, bloggers and tags", ctx do
    ctx
    |> edit_post()
    |> change_title("Renamed #{ctx.n}")
    |> form(@form)
    |> render_submit()

    post = saved(ctx)

    assert post.title == "Renamed #{ctx.n}"
    assert relations(post) == ctx.held
  end

  test "a tag picked after that change is saved beside the ones the post had", ctx do
    view = ctx |> edit_post() |> change_title("Renamed #{ctx.n}")

    view
    |> element("#multi-select-post_form-tag_ids input[name=_search_tag_ids]")
    |> render_focus()

    render_async(view, @await)

    view
    |> element(~s(#multi-select-post_form-tag_ids button[phx-value-id="#{ctx.extra_tag.id}"]))
    |> render_click()

    view |> form(@form) |> render_submit()

    post = saved(ctx)
    tags = Enum.sort([to_string(ctx.extra_tag.id) | ctx.held.tag_ids])

    assert post.title == "Renamed #{ctx.n}"
    assert relations(post) == %{ctx.held | tag_ids: tags}
  end

  test "a tag removed before that change stays removed, on the form and in the save", ctx do
    [gone, kept] = ctx.held.tag_ids
    view = edit_post(ctx)

    view
    |> element(
      ~s(#multi-select-post_form-tag_ids button[aria-label^="Remove"][phx-value-id="#{gone}"])
    )
    |> render_click()

    change_title(view, "Renamed #{ctx.n}")

    assert shown(view).tag_ids == [kept]

    view |> form(@form) |> render_submit()

    post = saved(ctx)

    assert post.title == "Renamed #{ctx.n}"
    assert relations(post) == %{ctx.held | tag_ids: [kept]}
  end
end
