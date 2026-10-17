# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.ScopeTest do
  @moduledoc """
  Every blog dashboard figure is read as its viewer, through the resources' own policies
  (`MishkaBlog.Dashboard.Scope`).

  One two-site fixture is read by every kind of viewer: a master (a user whose `site_id` is nil)
  counts both sites, each site's admin only its own, an editor (`admin:dashboard:blog:post`) no
  comment, a moderator (`admin:dashboard:blog:comment`) no post, view or blogger, and an account
  holding no blog area nothing at all — without a crash. A master's figures are read before and
  after the fixture is written, as other suites leave rows a master also counts.
  """
  use MishkaBlog.DataCase, async: false

  import Phoenix.LiveViewTest
  import MishkaBlog.Test.Factory

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlog.Dashboard.Scope
  alias MishkaBlog.Dashboard.Widgets.Bloggers
  alias MishkaBlog.Dashboard.Widgets.CommentsModeration
  alias MishkaBlog.Dashboard.Widgets.DraftsScheduled
  alias MishkaBlog.Dashboard.Widgets.RecentPosts
  alias MishkaBlog.Dashboard.Widgets.TopPosts
  alias MishkaCmsCore.Dashboard.Widget

  @widgets [RecentPosts, DraftsScheduled, CommentsModeration, TopPosts, Bloggers]

  setup do
    master = create_user_with_permissions!(["admin:dashboard:*"])

    before = %{
      overview: Overview.load(master),
      analytics: Analytics.load(master, 7)
    }

    site_a = create_site!()
    site_b = create_site!()

    read_a = create_blog_post!(site_id: site_a.id, title: "A Read", status: :published)
    quiet_a = create_blog_post!(site_id: site_a.id, title: "A Quiet", status: :published)
    create_blog_post!(site_id: site_a.id, title: "A Draft", status: :draft)

    create_blog_post!(
      site_id: site_a.id,
      title: "A Scheduled",
      status: :scheduled,
      scheduled_publish_at:
        DateTime.add(DateTime.utc_now(), 2, :day) |> DateTime.truncate(:second)
    )

    read_b = create_blog_post!(site_id: site_b.id, title: "B Read", status: :published)
    create_blog_post!(site_id: site_b.id, title: "B Draft", status: :draft)

    create_post_view!(post_id: read_a.id, referer: "https://news.example.com/item")
    create_post_view!(post_id: read_a.id)
    create_post_view!(post_id: read_b.id, referer: "https://other.example.org/")

    # A view of a post that is archived since is no longer counted, by anybody.
    gone_a = create_blog_post!(site_id: site_a.id, title: "A Gone", status: :published)
    create_post_view!(post_id: gone_a.id)

    gone_a
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_a.id, authorize?: false)
    |> Ash.destroy!()

    create_comment!(site_id: site_a.id, post_id: read_a.id, content: "A first comment")
    create_comment!(site_id: site_a.id, post_id: read_a.id, content: "A second comment")
    create_comment!(site_id: site_b.id, post_id: read_b.id, content: "B comment")

    blogger_a = create_blogger!(site_id: site_a.id, display_name: "A Writer")
    blogger_b = create_blogger!(site_id: site_b.id, display_name: "B Writer")
    create_post_blogger!(post_id: read_a.id, blogger_id: blogger_a.id)
    create_post_blogger!(post_id: read_b.id, blogger_id: blogger_b.id)

    %{
      before: before,
      master: master,
      site_a: site_a,
      site_b: site_b,
      read_a: read_a,
      quiet_a: quiet_a,
      blogger_a: blogger_a,
      blogger_b: blogger_b,
      admin_a: create_user_with_permissions!(["admin:dashboard:*"], site_id: site_a.id),
      admin_b: create_user_with_permissions!(["admin:dashboard:*"], site_id: site_b.id),
      editor_a: create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: site_a.id),
      moderator_a:
        create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: site_a.id),
      nobody_a: create_user!(site_id: site_a.id),
      bare_master: create_user!(),
      page_master: create_user_with_permissions!(["admin:dashboard:runtime:page"])
    }
  end

  describe "read_for/2 and query/3" do
    test "a master reads through the master read with no tenant", %{master: master} do
      assert Scope.read_for(master) == {:master_read, [actor: master]}
      assert Scope.read_for(master, :read_any) == {:read_any, [actor: master]}

      query = Scope.query(MishkaBlog.BlogPost, master)

      assert query.action.name == :master_read
      assert query.tenant == nil
    end

    test "a site's admin reads through the tenant read under its own site", %{
      admin_a: admin,
      site_a: site
    } do
      assert Scope.read_for(admin) == {:read, [actor: admin, tenant: site.id]}
      assert Scope.read_for(admin, :read_any) == {:read, [actor: admin, tenant: site.id]}

      query = Scope.query(MishkaBlog.BlogPost, admin)

      assert query.action.name == :read
      assert query.tenant == site.id
    end

    test "a missing viewer is refused rather than read as a master", context do
      assert_raise ArgumentError, fn -> Scope.read_for(context[:no_viewer]) end
    end

    test "a refusal is no data", %{nobody_a: nobody} do
      query = Scope.query(MishkaBlog.BlogPost, nobody)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.count(query)
      assert Scope.count(query) == 0
      assert Scope.list(query) == []
      assert Scope.list(query, 5) == []
    end
  end

  describe "the overview" do
    test "a master counts both sites", %{master: master, before: before} do
      added = added(Overview.load(master), before.overview)

      assert added.posts_published == 3
      assert added.posts_drafts == 2
      assert added.posts_scheduled == 1
      assert added.comments_total == 3
      assert added.comments_pending == 3
      assert added.views_total == 3
      assert added.bloggers_active == 2
    end

    test "each site's admin counts its own site alone", %{admin_a: admin_a, admin_b: admin_b} do
      a = Overview.load(admin_a)
      b = Overview.load(admin_b)

      assert {a.posts_published, a.posts_drafts, a.posts_scheduled} == {2, 1, 1}
      assert {a.comments_total, a.views_total, a.bloggers_active} == {2, 2, 1}
      assert a.engagement_rate == 100

      assert {b.posts_published, b.posts_drafts, b.posts_scheduled} == {1, 1, 0}
      assert {b.comments_total, b.views_total, b.bloggers_active} == {1, 1, 1}

      assert a.activity |> Enum.map(& &1.title) |> Enum.all?(&String.starts_with?(&1, "A "))
      assert b.activity |> Enum.map(& &1.title) |> Enum.all?(&String.starts_with?(&1, "B "))
    end

    test "the calendar is the viewer's site's", %{admin_a: admin_a, admin_b: admin_b} do
      assert calendar_titles(admin_a) == ["A Quiet", "A Read", "A Scheduled"]
      assert calendar_titles(admin_b) == ["B Read"]
    end

    test "a master's calendar holds both sites", %{master: master} do
      titles = calendar_titles(master)

      assert Enum.all?(["A Quiet", "A Read", "A Scheduled", "B Read"], &(&1 in titles))
      refute "A Gone" in titles
    end

    test "an editor reads no comment and a moderator no post, view or blogger", %{
      editor_a: editor,
      moderator_a: moderator
    } do
      e = Overview.load(editor)
      m = Overview.load(moderator)

      assert {e.posts_published, e.views_total, e.bloggers_active, e.comments_total} ==
               {2, 2, 1, 0}

      assert {m.posts_published, m.views_total, m.bloggers_active, m.comments_total} ==
               {0, 0, 0, 2}

      assert e.engagement_rate == 0
      assert m.engagement_rate == 0
      assert Enum.map(m.activity, & &1.kind) |> Enum.uniq() == [:comment]
      assert calendar_titles(moderator) == []
    end

    for actor <- [:nobody_a, :bare_master, :page_master] do
      test "#{actor} holds no blog area and reads nothing", context do
        stats = Overview.load(context[unquote(actor)])

        assert stats |> Map.drop([:activity, :tags_top]) |> Map.values() |> Enum.all?(&(&1 == 0))
        assert stats.activity == []
        assert stats.tags_top == nil
        assert calendar_titles(context[unquote(actor)]) == []
      end
    end
  end

  describe "the analytics page" do
    test "a master counts both sites", %{master: master, before: before} do
      stats = Analytics.load(master, 7)

      assert stats.views_window - before.analytics.views_window == 3
      assert stats.views_total - before.analytics.views_total == 3
      assert stats.comments_window - before.analytics.comments_window == 3
    end

    test "each site's admin reads its own site's readers alone", %{
      admin_a: admin_a,
      admin_b: admin_b
    } do
      a = Analytics.load(admin_a, 7)
      b = Analytics.load(admin_b, 7)

      assert {a.views_total, a.views_window, a.views_today, a.comments_window} == {2, 2, 2, 2}
      assert a.audience == %{members: 0, guests: 2}
      assert Enum.map(a.top_posts, &{&1.title, &1.views}) == [{"A Read", 2}]
      assert a.referrers |> Enum.map(& &1.label) |> Enum.sort() == ["Direct", "news.example.com"]
      assert Enum.sum(Enum.map(a.series, & &1.count)) == 2

      assert {b.views_total, b.views_window, b.comments_window} == {1, 1, 1}
      assert Enum.map(b.top_posts, &{&1.title, &1.views}) == [{"B Read", 1}]
      assert Enum.map(b.referrers, & &1.label) == ["other.example.org"]
    end

    test "a moderator reads the comments alone", %{moderator_a: moderator} do
      stats = Analytics.load(moderator, 7)

      assert {stats.views_total, stats.views_window, stats.visitors} == {0, 0, 0}
      assert stats.comments_window == 2
      assert stats.top_posts == []
      assert stats.referrers == []
    end

    for actor <- [:nobody_a, :bare_master, :page_master] do
      test "#{actor} holds no blog area and reads nothing", context do
        stats = Analytics.load(context[unquote(actor)], 7)

        assert {stats.views_total, stats.views_window, stats.comments_window} == {0, 0, 0}
        assert stats.top_posts == []
        assert stats.referrers == []
        assert stats.audience == %{members: 0, guests: 0}
      end
    end
  end

  describe "the widgets" do
    test "a site's admin reads its own site alone", %{
      admin_a: admin,
      read_a: read_a,
      blogger_a: blogger_a
    } do
      assert RecentPosts.load(admin).posts |> Enum.map(& &1.title) |> Enum.sort() ==
               ["A Draft", "A Quiet", "A Read", "A Scheduled"]

      assert %{drafts: 1, scheduled: 1, latest: latest} = DraftsScheduled.load(admin)
      assert latest |> Enum.map(& &1.title) |> Enum.sort() == ["A Draft", "A Scheduled"]

      assert %{counts: %{pending: 2}, latest: comments} = CommentsModeration.load(admin)

      assert comments |> Enum.map(& &1.content) |> Enum.sort() == [
               "A first comment",
               "A second comment"
             ]

      assert [%{id: top_id, view_count: 2}, %{view_count: 0}] = TopPosts.load(admin).posts
      assert top_id == read_a.id

      assert %{bloggers: [%{id: blogger_id, post_count: 1}], active_this_month: 1} =
               Bloggers.load(admin)

      assert blogger_id == blogger_a.id
    end

    test "a master reads both sites", %{
      master: master,
      read_a: read_a,
      blogger_a: blogger_a,
      blogger_b: blogger_b
    } do
      titles =
        master |> RecentPosts.load(%{"count" => 12}) |> Map.fetch!(:posts) |> Enum.map(& &1.title)

      assert Enum.all?(["A Read", "A Quiet", "B Read", "B Draft"], &(&1 in titles))

      contents =
        master
        |> CommentsModeration.load(%{"count" => 10})
        |> Map.fetch!(:latest)
        |> Enum.map(& &1.content)

      assert Enum.all?(["A first comment", "A second comment", "B comment"], &(&1 in contents))

      assert read_a.id in Enum.map(TopPosts.load(master, %{"count" => 12}).posts, & &1.id)

      bloggers =
        master |> Bloggers.load(%{"count" => 12}) |> Map.fetch!(:bloggers) |> Enum.map(& &1.id)

      assert blogger_a.id in bloggers
      assert blogger_b.id in bloggers
    end

    test "an editor's post widgets count the comments a post carries, as before", %{
      editor_a: editor,
      read_a: read_a
    } do
      post = Enum.find(RecentPosts.load(editor).posts, &(&1.id == read_a.id))

      assert post.comment_count == 2
      assert post.view_count == 2
    end

    test "an editor reads no comment queue and a moderator no post widget", %{
      editor_a: editor,
      moderator_a: moderator
    } do
      assert CommentsModeration.load(editor) == %{
               counts: %{pending: 0, flagged: 0, spam: 0, approved: 0},
               latest: []
             }

      assert RecentPosts.load(moderator).posts == []
      assert DraftsScheduled.load(moderator) == %{drafts: 0, scheduled: 0, latest: []}
      assert TopPosts.load(moderator) == %{posts: []}
      assert Bloggers.load(moderator) == %{active_this_month: 0, bloggers: []}
    end

    for actor <- [:nobody_a, :bare_master, :page_master], module <- @widgets do
      test "#{inspect(module)} reads nothing for #{actor} and still renders", context do
        user = context[unquote(actor)]
        data = unquote(module).load(user)

        assert data |> Map.delete(:count) |> Map.values() |> Enum.all?(&empty?/1)

        html =
          render_component(&Widget.card/1,
            widget: unquote(module).widget(),
            state: {:ok, data},
            current_user: user
          )

        refute html =~ "could not load"
      end
    end
  end

  test "no dashboard read skips the policies" do
    files = Path.wildcard(Path.expand("../../lib/mishka_blog/dashboard/**/*.ex", __DIR__))

    assert length(files) >= 8

    for file <- files do
      refute File.read!(file) =~ "authorize?: false", "#{Path.relative_to_cwd(file)} skips them"
    end
  end

  defp calendar_titles(user) do
    user
    |> Overview.calendar(Date.utc_today())
    |> Map.fetch!(:cells)
    |> Enum.flat_map(& &1.posts)
    |> Enum.map(& &1.title)
    |> Enum.concat(
      user
      |> Overview.calendar(Date.add(Date.utc_today(), 2))
      |> Map.fetch!(:cells)
      |> Enum.flat_map(& &1.posts)
      |> Enum.map(& &1.title)
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp empty?(value) when is_integer(value), do: value == 0
  defp empty?(value) when is_list(value), do: value == []
  defp empty?(%{} = map), do: map |> Map.values() |> Enum.all?(&empty?/1)

  defp added(after_load, before_load) do
    for {key, value} <- after_load, is_integer(value), into: %{} do
      {key, value - Map.fetch!(before_load, key)}
    end
  end
end
