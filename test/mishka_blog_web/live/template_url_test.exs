# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.TemplateUrlTest do
  @moduledoc """
  The Table/Cards switch of the blog's list pages, kept in the URL.

  Each page opens as cards. Switching to the table writes `template=table` to the URL, so a
  reload or a shared link shows the table again, and the URL of the cards opens the cards.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000

  setup %{conn: conn} do
    SiteState.clear()
    site = master_site()

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    n = System.unique_integer([:positive])

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin("template-url-#{n}@example.com"))

    {:ok, conn: conn}
  end

  for {page, card_template} <- [
        {"posts", "post_card"},
        {"collections", "card_grid"},
        {"tags", "tag_grid"},
        {"bloggers", "card_grid"},
        {"comments", "comment_card"},
        {"teams", "card_grid"}
      ] do
    @key "#{page}_template"
    @path "/admin/dashboard/blog/#{page}"
    @cards card_template

    describe "the #{page} page" do
      test "opens as cards, and the URL of the table opens the table", %{conn: conn} do
        assert conn |> open(@path) |> showing?(@cards)
        assert conn |> open("#{@path}?#{@key}=table") |> showing?("table")
      end

      test "switching to the table writes it to the URL, and that URL opens the table again",
           %{conn: conn} do
        view = open(conn, @path)

        view |> element(switcher("table")) |> render_click()
        render_async(view, @await)

        patched(view, @key, "table")
        assert showing?(view, "table")
        assert conn |> open("#{@path}?#{@key}=table") |> showing?("table")

        view |> element(switcher(@cards)) |> render_click()
        render_async(view, @await)

        patched(view, @key, @cards)
        assert conn |> open("#{@path}?#{@key}=#{@cards}") |> showing?(@cards)
      end

      test "a template the page does not offer leaves its own", %{conn: conn} do
        assert conn |> open("#{@path}?#{@key}=no_such_template") |> showing?(@cards)
      end
    end
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  # The page patches the URL as it opens too, so the patches are read in the order they were sent
  # until the one that carries the template; none after it means the URL never got it.
  defp patched(view, key, template) do
    case view |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() do
      %{^key => ^template} = params -> params
      _opening_patch -> patched(view, key, template)
    end
  end

  defp switcher(template),
    do: ~s(button[phx-click="switch_template"][phx-value-template="#{template}"])

  defp showing?(view, template),
    do: has_element?(view, ~s(#{switcher(template)}[aria-pressed="true"]))

  defp master_site do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.filter(master == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        create_site!(
          name: "localhost",
          host: "localhost",
          active: true,
          master: true
        )

      site ->
        site
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

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
