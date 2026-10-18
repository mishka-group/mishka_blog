# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.SeedsArchivalTest do
  @moduledoc """
  The one archival rule this extension's seeds have to respect.

  Several resources carry BOTH an `:archived` value in their status enum and an `archived_at`
  soft-delete timestamp, and only the timestamp decides which tab the admin shows a row in. A row
  holding the archived LABEL while staying live therefore reads, to anyone using the admin, as an
  archived record sitting in the Active tab — and a row soft-deleted WITHOUT the label reads the
  other way round in any list that colours by status.

  So for seeded data the two must agree: **status `:archived` if and only if `archived_at` is set.**

  Resources are discovered from the configured domains rather than listed, so a resource that later
  gains the second axis is covered the day it does. Comparison is raw SQL on purpose: these resources
  declare `base_filter_sql "(archived_at IS NULL)"`, so no Ash read can see both sides at once.

  Each extension owns this check for its own seeds; see `MishkaDocument.SeedsArchivalTest`.

  The seeds' locked and unlisted examples are held here too: written once per site by slug, with
  their permissions, robots meta and links, and never a second time over an archived or edited one.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  import MishkaBlog.Test.Factory

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Runtime.PageEditions

  @examples [
    {BlogPost, "members-only-release-checklist"},
    {BlogPost, "kept-out-of-search-engines"},
    {Collection, "members-only"},
    {Collection, "ideas-in-progress"},
    {Tag, "unlisted"},
    {Tag, "staff-only"}
  ]

  @doc false
  def two_axis_resources do
    :mishka_blog
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&two_axis?/1)
    |> Enum.map(&{&1, AshPostgres.DataLayer.Info.table(&1)})
    |> Enum.sort_by(fn {resource, _table} -> inspect(resource) end)
  end

  defp two_axis?(resource) do
    !is_nil(Ash.Resource.Info.attribute(resource, :archived_at)) and
      :archived in status_values(resource)
  end

  defp status_values(resource) do
    case Ash.Resource.Info.attribute(resource, :status) do
      %{constraints: constraints} -> Keyword.get(constraints, :one_of, [])
      _other -> []
    end
  end

  defp count(sql) do
    MishkaBlog.Repo
    |> Ecto.Adapters.SQL.query!(sql, [])
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end

  defp labelled_but_live(table),
    do:
      count(
        "SELECT count(*) FROM #{table} WHERE status::text = 'archived' AND archived_at IS NULL"
      )

  defp archived_without_label(table),
    do:
      count(
        "SELECT count(*) FROM #{table} WHERE archived_at IS NOT NULL AND status::text <> 'archived'"
      )

  defp archived(table), do: count("SELECT count(*) FROM #{table} WHERE archived_at IS NOT NULL")

  # THE EXTENSION'S OWN ROLE ACCOUNTS, which its seed adds once installing it has created the names.
  defp held_by(email, site_id) do
    MishkaCmsCore.Accounts.User
    |> Ash.Query.filter(email == ^email and site_id == ^site_id)
    |> Ash.Query.load(:permissions)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:permissions)
    |> Enum.map(& &1.name)
  end

  # The live rows of `resource` at `slug` on the site, with `loads`; `archived_at_slug/3` reads the
  # archived ones.
  defp at_slug(resource, site_id, slug, loads \\ []) do
    resource
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.Query.load(loads)
    |> Ash.read!(authorize?: false)
  end

  defp archived_at_slug(resource, site_id, slug) do
    resource
    |> Ash.Query.for_read(:archived, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read!(authorize?: false, page: [limit: 10])
    |> Map.fetch!(:results)
  end

  defp example!(resource, site_id, slug, loads \\ []) do
    [row] = at_slug(resource, site_id, slug, loads)
    row
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # The six examples as a re-run reads them back, the posts with their collections, tags and, for
  # the locked one, bloggers.
  defp seeded_examples(site) do
    assert MishkaBlog.Dev.Seeds.dev_seed(site.id, []) == :already_seeded

    %{
      locked:
        example!(BlogPost, site.id, "members-only-release-checklist", [
          :tenant_collections,
          :tenant_tags,
          :tenant_bloggers
        ]),
      unindexed:
        example!(BlogPost, site.id, "kept-out-of-search-engines", [
          :tenant_collections,
          :tenant_tags
        ]),
      category: example!(Collection, site.id, "members-only"),
      unindexed_category: example!(Collection, site.id, "ideas-in-progress"),
      unlisted: example!(Tag, site.id, "unlisted"),
      locked_tag: example!(Tag, site.id, "staff-only")
    }
  end

  # A full seed is expensive, so it runs ONCE for the whole file and every assertion about seeded
  # data lives in the single test below.
  describe "a seeded site" do
    setup do
      site = create_site!()
      users = [create_user!(site_id: site.id)]

      MishkaBlog.Dev.Seeds.dev_seed(site.id, users)

      %{site: site}
    end

    test "labels and timestamps agree, and the seeds really soft-delete", %{site: site} do
      assert held_by("writer@#{site.name}.test", site.id) == ["admin:dashboard:blog:post"]
      assert held_by("moderator@#{site.name}.test", site.id) == ["admin:dashboard:blog:comment"]

      offenders =
        for {resource, table} <- two_axis_resources(),
            live = labelled_but_live(table),
            orphan = archived_without_label(table),
            live > 0 or orphan > 0 do
          "#{inspect(resource)}: #{live} labelled-but-live, #{orphan} archived-without-label"
        end

      assert offenders == []

      assert archived("mishka_blog_posts") > 0

      # A fresh site gets the full seed above AND the examples after it.
      assert Enum.all?(@examples, fn {resource, slug} ->
               length(at_slug(resource, site.id, slug)) == 1
             end)
    end
  end

  # A site that already has a post skips the full seed, which is the cheap way to watch the examples
  # alone — and is the re-run on a seeded database they have to reach.
  describe "the locked and unlisted examples" do
    setup do
      site = create_site!()
      create_blog_post!(site_id: site.id)

      %{site: site, blogger: create_blogger!(site_id: site.id)}
    end

    test "are written published and in English, with their titles and permissions", %{site: site} do
      %{
        locked: locked,
        unindexed: unindexed,
        category: category,
        unindexed_category: unindexed_category,
        unlisted: unlisted,
        locked_tag: locked_tag
      } = seeded_examples(site)

      for post <- [locked, unindexed] do
        assert post.status == :published
        assert post.language == "en"
        assert DateTime.compare(post.published_at, DateTime.utc_now()) == :lt
      end

      assert locked.title == "Members only: the release checklist"
      assert locked.permissions == ["admin:dashboard:blog:post"]

      assert unindexed.title == "Kept out of search engines"
      assert unindexed.permissions == []

      assert {category.name, category.status, category.language} ==
               {"Members only", :active, "en"}

      assert category.permissions == ["admin:dashboard:blog:post"]

      assert {unlisted.name, unlisted.language, unlisted.permissions} == {"Unlisted", "en", []}

      assert {unindexed_category.name, unindexed_category.status, unindexed_category.permissions} ==
               {"Ideas in progress", :active, []}

      assert {locked_tag.name, locked_tag.permissions} ==
               {"Staff only", ["admin:dashboard:blog:post"]}
    end

    test "carry the robots meta only where they are kept out of search engines", %{site: site} do
      %{
        locked: locked,
        unindexed: unindexed,
        category: category,
        unindexed_category: unindexed_category,
        unlisted: unlisted,
        locked_tag: locked_tag
      } = seeded_examples(site)

      assert locked_tag.seo_tags == []

      for row <- [unindexed, unlisted, unindexed_category] do
        assert [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}] =
                 row.seo_tags
      end

      refute Enum.any?(
               [locked, unindexed, category, unindexed_category, unlisted, locked_tag],
               &PageEditions.listed?/1
             )
    end

    test "link each post to its collection and its tag", %{site: site} do
      %{
        locked: locked,
        unindexed: unindexed,
        category: category,
        unindexed_category: unindexed_category,
        unlisted: unlisted,
        locked_tag: locked_tag
      } = seeded_examples(site)

      assert ids(locked.tenant_collections) == [category.id]
      assert ids(locked.tenant_tags) == [locked_tag.id]

      assert ids(unindexed.tenant_tags) == [unlisted.id]
      assert ids(unindexed.tenant_collections) == [unindexed_category.id]
    end

    test "credit the locked post to the site's blogger", %{site: site, blogger: blogger} do
      %{locked: locked} = seeded_examples(site)

      assert ids(locked.tenant_bloggers) == [blogger.id]
    end

    test "a second run writes no second copy, and leaves an edited or archived one as it is", %{
      site: site
    } do
      MishkaBlog.Dev.Seeds.dev_seed(site.id, [])

      BlogPost
      |> example!(site.id, "members-only-release-checklist")
      |> Ash.update!(%{permissions: []}, action: :update, tenant: site.id, authorize?: false)

      Tag
      |> example!(site.id, "unlisted")
      |> Ash.destroy!(action: :destroy, tenant: site.id, authorize?: false)

      MishkaBlog.Dev.Seeds.dev_seed(site.id, [])

      locked =
        example!(BlogPost, site.id, "members-only-release-checklist", [:tenant_collections])

      assert locked.permissions == []
      assert length(locked.tenant_collections) == 1
      assert length(at_slug(BlogPost, site.id, "kept-out-of-search-engines")) == 1
      assert length(at_slug(Collection, site.id, "members-only")) == 1
      assert at_slug(Tag, site.id, "unlisted") == []
      assert length(archived_at_slug(Tag, site.id, "unlisted")) == 1
    end

    test "a site holding one of them gets the rest, linked to the one it has", %{site: site} do
      held =
        create_collection!(
          site_id: site.id,
          name: "Staff room",
          slug: "members-only",
          status: :active
        )

      MishkaBlog.Dev.Seeds.dev_seed(site.id, [])

      assert [%{id: id, name: "Staff room", permissions: []}] =
               at_slug(Collection, site.id, "members-only")

      assert id == held.id

      locked =
        example!(BlogPost, site.id, "members-only-release-checklist", [:tenant_collections])

      assert ids(locked.tenant_collections) == [held.id]
    end
  end

  # A guard on the discovery itself: were it ever to return [], the test above would pass vacuously
  # and stop protecting anything. Needs no seed, so it sits outside the describe.
  test "the discovery finds this extension's two-axis resources" do
    tables = two_axis_resources() |> Enum.map(&elem(&1, 1))

    assert "mishka_blog_posts" in tables
    assert "mishka_blog_collections" in tables
  end
end
