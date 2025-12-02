defmodule MishkaBlogWeb.Test.CommentAuthorLabelTest do
  @moduledoc """
  Who the Comments page says wrote each comment, on the card view and on the table view.

  A master reads every author's email. A site admin reads its own site's people by email, a master
  by the name of its blogger profile on the site or else as "Master", and never the master's email
  or any part of it. A comment written signed out reads "Guest".
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaBlogWeb.Templates.CommentCard
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000

  setup do
    SiteState.clear()
    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])
    site = create_site!(host: "comments-#{n}.localhost")
    remember(site)
    post = create_blog_post!(site_id: site.id)

    colleague = create_admin("comment-colleague-#{n}@example.com", site.id)
    master = create_admin("comment-master-#{n}@platform.test", nil)
    named_master = create_admin("comment-named-#{n}@platform.test", nil)
    create_blogger!(site_id: site.id, user_id: named_master.id, display_name: "Platform Team")

    {:ok,
     site: site,
     colleague: colleague,
     master: master,
     named_master: named_master,
     by_colleague: comment!(site, post, colleague),
     by_master: comment!(site, post, master),
     by_named_master: comment!(site, post, named_master),
     by_guest: comment!(site, post, nil)}
  end

  describe "the word for an author the card shows no email for" do
    test "is Unknown for an account the read did not return, Guest signed out, Master for a master" do
      id = Ash.UUID.generate()

      assert CommentCard.author(%{author_id: id}) == "Unknown"
      assert CommentCard.author(%{author_id: nil}) == "Guest"
      assert CommentCard.author(%{author_id: id, author_master?: true}) == "Master"
    end

    test "reads in the admin's language" do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      id = Ash.UUID.generate()

      assert CommentCard.author(%{author_id: id}) == "[fa] Unknown"
      assert CommentCard.author(%{author_id: nil}) == "[fa] Guest"
      assert CommentCard.author(%{author_id: id, author_master?: true}) == "[fa] Master"
    end
  end

  describe "a master" do
    setup %{site: site} do
      master_site = master_site()
      remember(master_site)
      n = System.unique_integer([:positive])

      conn =
        Phoenix.ConnTest.build_conn()
        |> on_host(master_site.host)
        |> log_in(create_admin("comment-reader-#{n}@platform.test", nil), master_mode: true)

      {:ok, conn: conn, site: site}
    end

    test "reads every author's email on the cards and on the table", ctx do
      view = open_comments(ctx.conn)

      for {template, read} <- [{"comment_card", &card_author/2}, {"table", &table_author/2}] do
        switch_to(view, template)

        assert read.(view, ctx.by_colleague) == to_string(ctx.colleague.email)
        assert read.(view, ctx.by_master) == to_string(ctx.master.email)
        assert read.(view, ctx.by_named_master) == to_string(ctx.named_master.email)
        assert read.(view, ctx.by_guest) == "Guest"
      end
    end
  end

  describe "a site's admin" do
    setup %{site: site} do
      n = System.unique_integer([:positive])

      conn =
        Phoenix.ConnTest.build_conn()
        |> on_host(site.host)
        |> log_in(create_admin("comment-site-admin-#{n}@example.com", site.id), [])

      {:ok, conn: conn}
    end

    test "reads its own people by email and a master by blogger name or as Master", ctx do
      view = open_comments(ctx.conn)

      for {template, read, initials} <- [
            {"comment_card", &card_author/2, &card_initials/2},
            {"table", &table_author/2, &table_initial/2}
          ] do
        switch_to(view, template)

        assert read.(view, ctx.by_colleague) == to_string(ctx.colleague.email)
        assert read.(view, ctx.by_master) == "Master"
        assert read.(view, ctx.by_named_master) == "Platform Team"
        assert read.(view, ctx.by_guest) == "Guest"
        assert initials.(view, ctx.by_master) == "M"
      end

      html = render(view)

      for master <- [ctx.master, ctx.named_master] do
        email = to_string(master.email)
        refute html =~ email
        refute html =~ email |> String.split("@") |> hd()
      end
    end
  end

  defp comment!(site, post, author) do
    MishkaBlog.Comment
    |> Ash.Changeset.for_create(
      :create,
      %{post_id: post.id, content: "A comment #{System.unique_integer()}", status: :pending},
      tenant: site.id,
      actor: author,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp open_comments(conn) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/blog/comments")
    render_async(view, @await)
    view
  end

  defp switch_to(view, template) do
    view
    |> element(~s([phx-click="switch_template"][phx-value-template="#{template}"]))
    |> render_click()

    render_async(view, @await)
  end

  defp card_author(view, comment), do: text(view, ~s([id$="#{comment.id}-author"]))
  defp card_initials(view, comment), do: text(view, ~s([id$="#{comment.id}-initials"]))
  defp table_author(view, comment), do: text(view, "#comment-author-#{comment.id}")
  defp table_initial(view, comment), do: text(view, "#comment-author-initial-#{comment.id}")

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
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

  defp on_host(conn, host) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp master_site do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.filter(master == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_site!(name: "localhost", host: "localhost", active: true, master: true)
      site -> site
    end
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email, site_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false,
        tenant: site_id
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user, opts) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> then(&if(opts[:master_mode], do: Plug.Conn.put_session(&1, :master_mode, true), else: &1))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
