defmodule MishkaBlogWeb.Test.TagAndPostTranslationsTest do
  @moduledoc """
  The tags page and the posts page, deleting an original edition whose translation is live.

  The Delete is refused while the translation is live, and the admin is told why in an alert that
  offers to archive the translation at once, asking first with its language named. Once it has,
  the original archives. The bulk Archive does the same, and so do Delete forever and the bulk
  Delete permanently on an archived original, offering to delete the translation for good. See
  `MishkaCmsCore.LanguageEditions`.
  """
  use MishkaBlog.ConnCase

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.{BlogPost, Tag}
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @alert "#translations-refusal-alert"
  @act "#translations-refusal-act"

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @refused "This is the original English version. Its Persian translation is still live, so it " <>
             "can't be deleted yet. Archive or delete that translation first, then this one."

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
      |> log_in(create_admin("tag-post-translations-#{n}@example.com"))

    {:ok, conn: conn, site: site}
  end

  for {resource, path, card, title, table} <- [
        {Tag, "/admin/dashboard/blog/tags", "tagchip", :name, "mishka_blog_tags"},
        {BlogPost, "/admin/dashboard/blog/posts", "bp-row", :title, "mishka_blog_posts"}
      ] do
    @resource resource
    @path path
    @card card
    @title title
    @table table

    test "#{inspect(resource)}: Delete keeps an original whose translation is live, says why, and archives the translation at once",
         %{conn: conn, site: site} do
      original = make(@resource, site, [])
      fa = make(@resource, site, language: "fa", language_group_id: original.id)
      title = Map.fetch!(original, @title)

      {:ok, view, _html} = live(conn, @path)
      render_async(view, @await)
      delete = ~s([data-role="#{@card}"][id$="#{original.id}"] button[phx-click="delete"])

      view |> element(delete) |> render_click()
      render(view)
      render_async(view, @await)

      assert live?(original), "the original was archived under its live translation"
      assert has_element?(view, @alert, @refused)
      refute has_element?(view, "#flash-error")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Persian translation of “#{title}”? You can restore it later."])
             )

      view |> element(@act) |> render_click()

      refute live?(fa), "the quick action left the translation live"
      assert live?(original), "the quick action archived the original too"

      view |> element(delete) |> render_click()

      refute live?(original)
    end

    test "#{inspect(resource)}: the bulk Archive keeps it too, and archives the translation at once",
         %{conn: conn, site: site} do
      original = make(@resource, site, [])
      fa = make(@resource, site, language: "fa", language_group_id: original.id)
      title = Map.fetch!(original, @title)

      view = open(conn, @path)
      select(view, @card, original)
      bulk(view, "archive")
      refused(view)

      assert live?(original), "the bulk archive archived the original under its live translation"
      assert has_element?(view, @alert, @refused)
      refute has_element?(view, "#flash-error")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Persian translation of “#{title}”? You can restore it later."])
             )

      view |> element(@act) |> render_click()

      refute live?(fa)

      assert stored?(fa),
             "the quick action deleted the translation for good instead of archiving it"

      assert live?(original)

      bulk(view, "archive")

      refute live?(original)
    end

    test "#{inspect(resource)}: Delete forever keeps an archived original whose translation is live, and deletes the translation for good at once",
         %{conn: conn, site: site} do
      original = make(@resource, site, [])
      fa = make(@resource, site, language: "fa", language_group_id: original.id)
      shelve!(@table, original)
      title = Map.fetch!(original, @title)

      view = open_archive(conn, @path)
      forever = ~s(#{card(@card, original)} [phx-value-event="permanent_destroy"])

      view |> element(forever) |> render_click()
      refused(view)

      assert stored?(original), "the original was deleted for good under its live translation"
      assert has_element?(view, @alert, @refused)
      refute has_element?(view, "#flash-error")
      assert has_element?(view, @act, "Delete the translations for good")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Delete the Persian translation of “#{title}” for good? This can't be undone."])
             )

      view |> element(@act) |> render_click()

      refute stored?(fa), "the quick action left the translation stored"
      assert stored?(original), "the quick action deleted the original too"

      view |> element(forever) |> render_click()

      refute stored?(original)
    end

    test "#{inspect(resource)}: the bulk Delete permanently keeps it too, and offers the same",
         %{conn: conn, site: site} do
      original = make(@resource, site, [])
      fa = make(@resource, site, language: "fa", language_group_id: original.id)
      shelve!(@table, original)

      view = open_archive(conn, @path)
      select(view, @card, original)
      bulk(view, "permanent_destroy")
      refused(view)

      assert stored?(original)
      assert has_element?(view, @alert, @refused)
      refute has_element?(view, "#flash-error")
      assert has_element?(view, @act, "Delete the translations for good")

      view |> element(@act) |> render_click()

      refute stored?(fa)
      assert stored?(original)

      bulk(view, "permanent_destroy")

      refute stored?(original)
    end

    test "#{inspect(resource)}: Restore keeps a translation while its original is archived, and says why",
         %{conn: conn, site: site} do
      original = make(@resource, site, [])
      fa = make(@resource, site, language: "fa", language_group_id: original.id)
      :ok = Ash.destroy(fa, action: :master_destroy, authorize?: false)
      :ok = Ash.destroy(original, action: :master_destroy, authorize?: false)

      view = open_archive(conn, @path)
      view |> element(~s(#{card(@card, fa)} [phx-value-event="unarchive"])) |> render_click()

      assert archived?(fa), "the translation came back under its archived original"

      assert has_element?(
               view,
               "#flash-error",
               "This is the Persian translation. Its original English version is archived, so " <>
                 "it can't be restored yet. Restore the original first, then this one."
             )
    end
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  defp open_archive(conn, path) do
    view = open(conn, path)

    view
    |> element(~s(button[phx-click="archive_filter"][phx-value-status="archived"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  defp card(role, record), do: ~s([data-role="#{role}"][id$="#{record.id}"])

  defp select(view, role, record) do
    view |> element(~s(#{card(role, record)} [phx-click="toggle_select"])) |> render_click()
    view
  end

  defp bulk(view, action) do
    view
    |> element(~s(button[phx-click="bulk_action"][phx-value-action="#{action}"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  # THE ALERT ARRIVES AS AN UPDATE THE TABLE SENDS THE PAGE, run after the render that delivered the
  # click, and then reads what it shows off the page's process.
  defp refused(view) do
    render(view)
    render_async(view, @await)
    view
  end

  # What the Delete left behind before it was refused: an archived original under a live translation.
  defp shelve!(table, record) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE #{table} SET archived_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(record.id)]
    )
  end

  defp archived?(record),
    do:
      match?(
        {:ok, %{archived_at: %DateTime{}}},
        Ash.get(record.__struct__, record.id, action: :master_get_archived, authorize?: false)
      )

  defp stored?(record),
    do:
      match?(
        {:ok, _},
        Ash.get(record.__struct__, record.id, action: :master_get, authorize?: false)
      )

  defp make(Tag, site, overrides), do: create_blog_tag!([site_id: site.id] ++ overrides)

  defp make(BlogPost, site, overrides),
    do: create_blog_post!([site_id: site.id, status: :published] ++ overrides)

  defp live?(record),
    do:
      match?(
        {:ok, %{archived_at: nil}},
        Ash.get(record.__struct__, record.id, action: :master_get, authorize?: false)
      )

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
