defmodule MishkaBlogWeb.Test.AdminFormFieldsTest do
  @moduledoc """
  The blog's admin forms draw each field as the box it holds, and fill a record's slug while the
  record is added.

  A title and an image address are one line — an `<input>`, never a textarea. Every textarea the
  post form draws besides the content editor — the subtitle, the excerpt, an SEO tag's content —
  carries the Tailwind adapter's field class, so it is bordered and as wide as its group, though the
  form is drawn by `MishkaCmsCoreWeb.UIAdapters.Admin`. The post form asks for the Site before the
  Language Group, whose picker waits on it.

  While a post, a collection, a tag, a team or a blogger is added, typing its title (a blogger's
  display name, the others' name) fills the slug with the one the save stores, through
  `MishkaCmsCore.Runtime.Helpers.follow_slug/4`. A slug the author types is kept from then on, and
  editing a record's title never moves its slug.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaGervaz.UIAdapters.Tailwind

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
    site = create_site!(name: "Fields #{n}", host: "fields-#{n}.localhost", active: true)
    Enum.each([home, site], &remember/1)

    {:ok,
     conn: conn,
     n: n,
     home: home,
     site: site,
     admin:
       create_user_with_permissions!(["*"], email: "fields-#{n}@example.com", site_id: site.id),
     master: create_user_with_permissions!(["*"], email: "fields-master-#{n}@example.com")}
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

  defp open(ctx, path), do: ctx.conn |> signed_in(ctx.admin, ctx.site.host) |> visit(path)

  defp open_as_master(ctx, path),
    do: ctx.conn |> signed_in(ctx.master, ctx.home.host, master_mode: true) |> visit(path)

  defp signed_in(conn, user, host, opts \\ []) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> then(&if(opts[:master_mode], do: Plug.Conn.put_session(&1, :master_mode, true), else: &1))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp visit(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  # One keystroke's `phx-change`: the form sends every field it shows, with `field` changed.
  defp type(view, form, field, value) do
    view
    |> form(form, %{"form" => %{to_string(field) => value}})
    |> render_change(%{"_target" => ["form", to_string(field)]})

    render_async(view, @await)
    view
  end

  defp shown(view, form, field) do
    view
    |> element("#{form} input[name='form[#{field}]']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp class(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("class")
  end

  defp position(html, needle) do
    {at, _length} = :binary.match(html, needle)
    at
  end

  defp saved_post(site, title) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(title == ^title and site_id == ^site.id)
    |> Ash.read_one!(authorize?: false)
  end

  describe "the post form" do
    test "draws the title and the image address on one line", ctx do
      view = open(ctx, @posts)

      assert has_element?(view, "#{@form} input[type=text][name='form[title]']")
      refute has_element?(view, "#{@form} textarea[name='form[title]']")
      assert has_element?(view, "#{@form} input[name='form[featured_image_url]'][dir=ltr]")
      refute has_element?(view, "#{@form} textarea[name='form[featured_image_url]']")
    end

    test "draws every textarea but the content editor as the adapter's full-width field", ctx do
      view = open(ctx, @posts)
      field = Tailwind.multiline_class("")

      assert field =~ "w-full"
      assert class(view, "#{@form} textarea[name='form[subtitle]'][rows='2']") == [field]
      assert class(view, "#{@form} textarea[name='form[excerpt]'][rows='3']") == [field]

      view |> element("#{@form} button[phx-click=add_nested]", "Add SEO Tag") |> render_click()
      render_async(view, @await)

      assert class(view, "#{@form} textarea[name^='form[seo_tags]'][name$='[content]']") == [
               field
             ]
    end

    test "asks a master for the site before the language group that waits on it", ctx do
      html = ctx |> open_as_master(@posts) |> element(@form) |> render()

      drawn =
        ~w(title slug status language site_id language_group_id featured)a
        |> Enum.sort_by(&position(html, ~s(id="post_form-form_#{&1}-label")))

      assert drawn == ~w(title slug status language site_id language_group_id featured)a
    end
  end

  describe "a post's slug" do
    test "follows the title while the post is added, and is saved as shown", ctx do
      view = open(ctx, @posts)

      type(view, @form, :title, "Hello. World!")
      assert shown(view, @form, :slug) == "hello.-world!"

      type(view, @form, :title, "Persian قیمت‌گذاری")
      assert shown(view, @form, :slug) == "persian-qymtgdhry"

      view
      |> form(@form, %{"form" => %{"status" => "draft"}})
      |> render_submit(%{"form" => %{"content" => "<p>Body</p>"}})

      assert saved_post(ctx.site, "Persian قیمت‌گذاری").slug == "persian-qymtgdhry"
    end

    test "stays as the author typed it once they type one", ctx do
      view = open(ctx, @posts)

      type(view, @form, :title, "First Title")
      assert shown(view, @form, :slug) == "first-title"

      type(view, @form, :slug, "my-own-slug")
      type(view, @form, :title, "Second Title")
      assert shown(view, @form, :slug) == "my-own-slug"
    end

    test "is kept when an existing post's title is edited", ctx do
      stored = create_blog_post!(site_id: ctx.site.id, title: "Stored #{ctx.n}")
      view = open(ctx, @posts)

      view
      |> element(~s([phx-click*="#{stored.id}"][phx-click*='"event":"edit"']))
      |> render_click()

      render_async(view, @await)
      assert has_element?(view, "#{@form}[method=put]")

      type(view, @form, :title, "Renamed #{ctx.n}")
      assert shown(view, @form, :slug) == stored.slug

      view |> form(@form) |> render_submit()

      assert saved_post(ctx.site, "Renamed #{ctx.n}").slug == stored.slug
    end
  end

  describe "the other blog forms" do
    @forms [
      {"/admin/dashboard/blog/collections", "#collection_form-form", :name},
      {"/admin/dashboard/blog/tags", "#tag_form-form", :name},
      {"/admin/dashboard/blog/teams", "#team_form-form", :name},
      {"/admin/dashboard/blog/bloggers", "#blogger_form-form", :display_name}
    ]

    test "fill the slug from the name while a record is added, until the author types one",
         ctx do
      for {path, form, field} <- @forms do
        view = open(ctx, path)

        type(view, form, field, "Rock & Roll Night")
        assert shown(view, form, :slug) == "rock-roll-night", "#{form} did not follow #{field}"

        type(view, form, :slug, "own-slug")
        type(view, form, field, "Another Name")
        assert shown(view, form, :slug) == "own-slug", "#{form} moved a typed slug"
      end
    end

    test "draw a team's and a blogger's image addresses on one line", ctx do
      for {path, form} <- [
            {"/admin/dashboard/blog/teams", "#team_form-form"},
            {"/admin/dashboard/blog/bloggers", "#blogger_form-form"}
          ],
          field <- ~w(avatar_url cover_image_url) do
        view = open(ctx, path)

        assert has_element?(view, "#{form} input[type=text][name='form[#{field}]'][dir=ltr]")
        refute has_element?(view, "#{form} textarea[name='form[#{field}]']")
      end
    end
  end
end
