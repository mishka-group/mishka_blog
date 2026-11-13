# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.AnalyticsTest do
  @moduledoc """
  The blog analytics page's numbers, read as a master and as a site's admin.

  `MishkaBlog.Dashboard.Analytics.load/2` reads as the viewer through the resources' own policies
  (`MishkaBlog.Dashboard.Scope`): a master (a user whose `site_id` is nil) counts every site, a
  site's admin only its own.
  """
  use MishkaBlog.DataCase, async: false

  import MishkaBlog.Test.Factory

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index

  defp window(user, days, comments? \\ true),
    do: Analytics.load(:overview, user, Analytics.period(%{"days" => to_string(days)}), comments?)

  test "a master counts every site's comments, a site's admin only its own" do
    site_a = create_site!()
    site_b = create_site!()
    master = create_user_with_permissions!(["admin:dashboard:*"])
    admin_a = create_user_with_permissions!(["admin:dashboard:*"], site_id: site_a.id)

    master_before = window(master, 7).comments_window
    admin_before = window(admin_a, 7).comments_window

    create_comment!(site_id: site_a.id)
    create_comment!(site_id: site_b.id)

    assert window(master, 7).comments_window == master_before + 2
    assert window(admin_a, 7).comments_window == admin_before + 1
  end

  # VIEWS AND POSTS ARE THE POST AREA'S, COMMENTS THE COMMENT AREA'S: a figure of an area the viewer
  # does not hold is read as zero, and the engagement rate needs both.
  describe "by area" do
    setup do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, status: :published)
      create_post_views!(post: post)
      create_comment!(site_id: site.id, post_id: post.id)

      %{site: site}
    end

    defp admin(site, names), do: create_user_with_permissions!(names, site_id: site.id)

    test "an editor reads the views and posts, and no comment", %{site: site} do
      stats = window(admin(site, ["admin:dashboard:blog:post"]), 7, false)

      posts =
        Analytics.load(
          :posts,
          admin(site, ["admin:dashboard:blog:post"]),
          Analytics.period(%{"days" => "7"}),
          false
        )

      assert stats.views_window == 1
      assert [%{views: 1, comments: nil, engagement: nil}] = posts.top
      assert stats.comments_window == nil
      assert stats.comments == nil
      assert stats.engagement_rate == nil
    end

    test "a moderator reads the comments, and no view or post", %{site: site} do
      moderator = admin(site, ["admin:dashboard:blog:comment"])
      stats = window(moderator, 7)

      assert stats.comments_window == 1
      assert stats.views_window == 0
      assert stats.views_total == 0
      assert Analytics.load(:posts, moderator, Analytics.period(%{"days" => "7"}), true).top == []
      assert stats.engagement_rate == 0
    end

    test "a holder of both reads the engagement rate", %{site: site} do
      stats =
        window(admin(site, ["admin:dashboard:blog:post", "admin:dashboard:blog:comment"]), 7)

      assert stats.engagement_rate == 100
    end
  end

  # EVERY PANEL IS ONE GROUPED READ OF THE DAILY ROWS: the numbers below are sums of rows seeded on
  # known days, so each assertion is what the GROUP BY must have added up.
  describe "the panels" do
    setup do
      site = create_site!()
      today = Date.utc_today()
      old = DateTime.add(DateTime.utc_now(), -60 * 86_400, :second) |> DateTime.truncate(:second)

      fresh = create_blog_post!(site_id: site.id, status: :published, title: "Fresh")

      older =
        create_blog_post!(site_id: site.id, status: :published, title: "Older", published_at: old)

      quiet =
        create_blog_post!(site_id: site.id, status: :published, title: "Quiet", published_at: old)

      # Fresh: 5 today, 3 two days ago; 2 in the window before. Older: 4 today; 10 in the window before.
      create_post_views!(post: fresh, views: 5, unique_readers: 2, day: today)
      create_post_views!(post: fresh, views: 3, unique_readers: 1, day: Date.add(today, -2))
      create_post_views!(post: fresh, views: 2, day: Date.add(today, -8))
      create_post_views!(post: older, views: 4, unique_readers: 4, day: today)
      create_post_views!(post: older, views: 10, day: Date.add(today, -9))
      create_post_views!(post: quiet, views: 1, day: today)

      news = create_collection!(site_id: site.id, name: "News")
      guides = create_collection!(site_id: site.id, name: "Guides")
      create_post_collection!(post_id: fresh.id, collection_id: news.id)
      create_post_collection!(post_id: older.id, collection_id: guides.id)

      elixir = create_blog_tag!(site_id: site.id, name: "elixir")
      create_post_tag!(post_id: fresh.id, tag_id: elixir.id)

      ada = create_blogger!(site_id: site.id, display_name: "Ada")
      bob = create_blogger!(site_id: site.id, display_name: "Bob")
      create_post_blogger!(post_id: fresh.id, blogger_id: ada.id)
      create_post_blogger!(post_id: older.id, blogger_id: bob.id)
      team = create_team!(site_id: site.id)
      create_team_member!(team_id: team.id, blogger_id: bob.id)

      create_comment!(site_id: site.id, post_id: fresh.id, guest_name: "Grace")
      create_comment!(site_id: site.id, post_id: fresh.id, guest_name: "Grace")

      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      %{
        admin: admin,
        posts: %{fresh: fresh, older: older, quiet: quiet},
        ids: %{news: news.id, guides: guides.id, elixir: elixir.id, ada: ada.id, team: team.id}
      }
    end

    defp panel(name, user, params \\ %{}, comments? \\ true),
      do:
        Analytics.load(name, user, Analytics.period(Map.put_new(params, "days", "7")), comments?)

    test "the overview adds the days up, the window before and the weekdays", %{admin: admin} do
      stats = panel(:overview, admin)

      assert stats.views_window == 13
      assert stats.views_previous == 12
      assert stats.views_today == 10
      assert stats.views_total == 25
      assert stats.visitors == 7
      assert length(stats.series) == 7
      assert length(stats.previous_series) == 7
      assert Enum.sum_by(stats.weekdays, & &1.count) == 13
      assert Enum.sum_by(stats.weeks, & &1.views) == 13
      assert Enum.sum_by(stats.weeks, & &1.posts) == 1
      assert stats.comments.window == 2
    end

    test "categories, tags and bloggers are ranked by their posts' views", %{
      admin: admin,
      ids: ids
    } do
      categories = panel(:categories, admin)

      assert [%{id: news, name: "News", views: 8}, %{name: "Guides", views: 4}] = categories.top
      assert news == ids.news
      assert Enum.sum_by(categories.series, &Map.get(&1.counts, :other, 0)) == 1
      assert Enum.sum_by(categories.series, &Map.get(&1.counts, ids.news, 0)) == 8

      assert [%{name: "elixir", views: 8, share: 100}] = panel(:tags, admin)

      assert [
               %{name: "Ada", views: 8, posts: 1, comments: 2},
               %{name: "Bob", views: 4, comments: 0}
             ] =
               panel(:bloggers, admin)
    end

    test "an archived blogger keeps its name in the panels and leaves the filter", %{
      admin: admin,
      ids: ids
    } do
      ada = Ash.get!(MishkaBlog.Blogger, ids.ada, action: :master_get, authorize?: false)

      ada
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: ada.site_id, authorize?: false)
      |> Ash.destroy!()

      assert %{name: "Ada", archived?: true} =
               Enum.find(panel(:bloggers, admin), &(&1.id == ids.ada))

      {listed, false} = Analytics.choices(:blogger, admin, [])
      refute ids.ada in Enum.map(listed, &elem(&1, 1))

      assert Index.name_of(%{name: "Ada", archived?: true}) == "Ada (archived)"
    end

    test "post age splits the views at thirty days", %{admin: admin} do
      assert %{fresh: 8, older: 5} = panel(:post_age, admin)
    end

    test "the post tables rank, compare and find the quiet ones", %{admin: admin, posts: posts} do
      %{top: top, rising: rising, quiet: quiet} = panel(:posts, admin, %{"sort" => "views"})

      assert [
               %{title: "Fresh", views: 8, readers: 3, comments: 2, engagement: 25, change: 300}
               | _
             ] = top

      assert Enum.map(top, & &1.title) == ["Fresh", "Older", "Quiet"]
      assert [%{title: "Fresh", change: 300}, %{title: "Quiet"}] = rising
      assert Enum.map(quiet, & &1.id) == [posts.quiet.id]

      assert Enum.map(Analytics.sort_posts(top, :change), & &1.title) |> hd() == "Fresh"
    end

    test "a filter narrows every figure to its posts", %{admin: admin, ids: ids} do
      assert panel(:overview, admin, %{"category" => ids.guides}).views_window == 4
      assert panel(:overview, admin, %{"tag" => ids.elixir}).views_window == 8
      assert panel(:overview, admin, %{"blogger" => ids.ada}).comments.window == 2
      assert panel(:overview, admin, %{"team" => ids.team}).views_window == 4
      assert [%{title: "Older"}] = panel(:posts, admin, %{"team" => ids.team}).top

      assert panel(:post_age, admin, %{"team" => ids.team}) |> Map.take([:fresh, :older]) == %{
               fresh: 0,
               older: 4
             }
    end

    test "a team counts each of its posts' views once, however many members wrote it", %{
      admin: admin,
      ids: ids,
      posts: posts
    } do
      second = create_blogger!(site_id: posts.older.site_id)
      create_post_blogger!(post_id: posts.older.id, blogger_id: second.id)
      create_team_member!(team_id: ids.team, blogger_id: second.id)

      assert [%{id: team, views: 4, share: 100}] = panel(:teams, admin)
      assert team == ids.team
    end

    test "comments are counted by status, and not read without the comment area", %{
      admin: admin
    } do
      assert panel(:comment_status, admin) == %{pending: 2, approved: 0, flagged: 0, spam: 0}
      assert panel(:comment_status, admin, %{}, false) == nil
    end

    test "commenters count who wrote in the window, and need the comment area", %{admin: admin} do
      assert [%{count: 2, comment: %{guest_name: "Grace"}}] = panel(:commenters, admin)
      assert panel(:commenters, admin, %{}, false) == []
      assert [%{comments: nil} | _] = panel(:bloggers, admin, %{}, false)
    end
  end

  describe "the filter choices" do
    test "come a page at a time, searched by name, with the archived left out" do
      site = create_site!()
      master = create_user_with_permissions!(["admin:dashboard:*"])
      n = System.unique_integer([:positive])
      tags = for i <- 1..25, do: create_blog_tag!(site_id: site.id, name: "zz#{n}-#{i}")
      gone = create_blog_tag!(site_id: site.id, name: "zz#{n}-gone")

      gone
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      {first, true} = Analytics.choices(:tag, master, search: "zz#{n}")
      {rest, false} = Analytics.choices(:tag, master, search: "zz#{n}", offset: 20)
      ids = Enum.map(first ++ rest, &elem(&1, 1))

      assert length(first) == 20
      assert Enum.sort(ids) == tags |> Enum.map(& &1.id) |> Enum.sort()
      refute gone.id in ids
      assert {[], false} = Analytics.choices(:tag, master, search: "100%_none#{n}")
    end

    test "tell repeated names apart by language and site, also for the one picked" do
      site_a = create_site!(name: "Site A")
      site_b = create_site!(name: "Site B")
      master = create_user_with_permissions!(["admin:dashboard:*"])
      name = "Travel #{System.unique_integer([:positive])}"
      a = create_collection!(site_id: site_a.id, name: name, language: "en")
      b = create_collection!(site_id: site_b.id, name: name, language: "de")
      solo = create_collection!(site_id: site_a.id, name: "Solo #{System.unique_integer()}")

      {found, false} = Analytics.choices(:category, master, search: name)
      labels = Map.new(found, fn {label, id} -> {id, label} end)

      assert labels[a.id] == "#{name} · en · #{site_a.name}"
      assert labels[b.id] == "#{name} · de · #{site_b.name}"
      assert {[{label, _id}], false} = Analytics.choices(:category, master, id: a.id)
      assert label == labels[a.id]
      assert {[{solo_label, _id}], false} = Analytics.choices(:category, master, id: solo.id)
      assert solo_label == solo.name

      twin =
        create_collection!(
          site_id: site_a.id,
          name: name,
          language: "en",
          slug: "twin-#{System.unique_integer([:positive])}"
        )

      {found, false} = Analytics.choices(:category, master, search: name)
      labels = Map.new(found, fn {label, id} -> {id, label} end)

      assert labels[twin.id] == "#{name} · en · #{site_a.name} · #{twin.slug}"
      assert labels[b.id] == "#{name} · de · #{site_b.name}"
    end
  end

  describe "the period" do
    test "reads the URL and writes back only what is not the default" do
      id = Ecto.UUID.generate()

      period =
        Analytics.period(%{"days" => "90", "tag" => id, "team" => "nope", "compare" => "true"})

      assert period.days == 90
      assert period.filters == %{tag: id}
      assert Date.diff(period.to, period.from) == 89
      assert Date.diff(period.previous_to, period.previous_from) == 89
      assert Analytics.params(period) == %{"days" => "90", "tag" => id, "compare" => "true"}
      assert Analytics.params(Analytics.period(%{"days" => "12"})) == %{}
    end
  end

  describe "the engagement rate" do
    test "is the share of views with a comment, never above all of them" do
      assert MishkaBlog.Dashboard.Figures.rate(1, 4) == 25
      assert MishkaBlog.Dashboard.Figures.rate(9, 1) == 100
      assert MishkaBlog.Dashboard.Figures.rate(3, 0) == 0
    end

    test "says New, not a delta, when the window before had none" do
      cards = fn engagement_rate, engagement_previous ->
        %{
          views_total: 10,
          views_window: 10,
          views_previous: 0,
          visitors: 1,
          views_today: 1,
          views_yesterday: 0,
          engagement_rate: engagement_rate,
          engagement_previous: engagement_previous
        }
        |> Index.kpi_cards(30, %{post: true, comment: true})
        |> List.last()
      end

      assert {"Engagement", _, _, "40%", "New", _} = cards.(40, 0)
      assert {"Engagement", _, _, "0%", "No data", _} = cards.(0, 0)
      assert {"Engagement", _, _, "40%", "+10 pts vs prev. 30d", _} = cards.(40, 30)
    end
  end

  describe "the page's labels" do
    test "write the chart's days and a post's publishing day" do
      assert Index.day_label(~D[2026-07-20]) == "Jul 20"
      assert Index.day_label(~D[2026-01-03]) == "Jan 3"

      assert Index.published_label(%{published_at: ~U[2026-07-03 10:00:00Z]}) ==
               "Published Jul 3, 2026"

      assert Index.published_label(%{published_at: nil}) == "Not published"
    end
  end
end
