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

  test "a master counts every site's comments, a site's admin only its own" do
    site_a = create_site!()
    site_b = create_site!()
    master = create_user_with_permissions!(["admin:dashboard:*"])
    admin_a = create_user_with_permissions!(["admin:dashboard:*"], site_id: site_a.id)

    master_before = Analytics.load(master, 7).comments_window
    admin_before = Analytics.load(admin_a, 7).comments_window

    create_comment!(site_id: site_a.id)
    create_comment!(site_id: site_b.id)

    assert Analytics.load(master, 7).comments_window == master_before + 2
    assert Analytics.load(admin_a, 7).comments_window == admin_before + 1
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
      stats = Analytics.load(admin(site, ["admin:dashboard:blog:post"]), 7)

      assert stats.views_window == 1
      assert [%{views: 1}] = stats.top_posts
      assert stats.comments_window == 0
      assert stats.engagement_rate == 0
    end

    test "a moderator reads the comments, and no view or post", %{site: site} do
      stats = Analytics.load(admin(site, ["admin:dashboard:blog:comment"]), 7)

      assert stats.comments_window == 1
      assert stats.views_window == 0
      assert stats.views_total == 0
      assert stats.top_posts == []
      assert stats.engagement_rate == 0
    end

    test "a holder of both reads the engagement rate", %{site: site} do
      stats =
        Analytics.load(
          admin(site, ["admin:dashboard:blog:post", "admin:dashboard:blog:comment"]),
          7
        )

      assert stats.engagement_rate == 100
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
