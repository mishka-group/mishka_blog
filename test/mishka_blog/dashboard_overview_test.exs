defmodule MishkaBlog.Dashboard.OverviewTest do
  @moduledoc """
  The blog admin overview page (`/admin/dashboard/blog`) is one read module plus a wall of pure
  presentation functions, and both halves fail silently: a wrong filter in
  `MishkaBlog.Dashboard.Overview` shows a tenant another site's numbers, and a shape drift in
  `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index` breaks a template that only renders in the admin.

  So this suite runs `load/1` and `calendar/2` against the test DB — as a master (a user whose
  `site_id` is nil) over
  seeded rows, and as a tenant with rows on two sites so cross-site leakage raises here — and it
  pins every label, tone and abbreviation the page derives from those numbers. The loading state
  matters as much as the loaded one: `kpi_cards/2`, `section_cards/2` and `month_rows/2` with `nil`
  are what the page paints before the async read lands, so they are asserted to carry the same
  arity and tuple shape as their loaded counterparts.

  The bad paths are deliberate. An empty database must divide no counts by zero, an absent calendar
  must yield no posts, and every boundary of `compact/1`, `growth/2` and `ago/1` is checked from
  both sides.
  """
  use MishkaBlog.DataCase, async: false

  import MishkaBlog.Test.Factory

  # A master is a user whose `site_id` is nil — not a missing user, which `Widget.scope/1` refuses
  # precisely so a caller that lost its user cannot read every site by accident.
  defp master, do: create_user_with_permissions!(["admin:dashboard:*"])

  # A site's admin of both blog areas, as the viewer map the dashboard hands over.
  defp site_admin(site_id, names \\ ["admin:dashboard:*"]),
    do: %{site_id: site_id, permissions: Enum.map(names, &%{name: &1})}

  @both %{post: true, comment: true}

  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index

  @body "text-[#1b1a18]"
  @muted "text-[#8a877f]"
  @up "text-[#177a53]"
  @down "text-[#b3433a]"
  @waiting "text-[#a8a5a0]"

  describe "load/1 as a master" do
    test "counts both sites' rows" do
      before = Overview.load(master())
      seed_two_sites()

      added = added(Overview.load(master()), before)

      assert added.posts_published == 3
      assert added.posts_drafts == 2
      assert added.posts_scheduled == 1
      assert added.comments_total == 3
      assert added.bloggers_active == 2
      assert added.collections_total == 2
      assert added.tags_total == 3
    end

    test "reports the numbers the This Month panel and section cards read" do
      before = Overview.load(master())
      site = create_site!()
      post = create_blog_post!(site_id: site.id, status: :published)
      collection = create_collection!(site_id: site.id, status: :active)
      create_post_collection!(post_id: post.id, collection_id: collection.id)
      create_blogger!(site_id: site.id, can_publish_directly: true)
      create_team!(site_id: site.id, status: :active)
      create_auto_posting!(site_id: site.id, is_active: true)
      create_post_view!(post_id: post.id)

      added = added(Overview.load(master()), before)

      assert added.posts_organised == 1
      assert added.bloggers_publishers == 1
      assert added.bloggers_new == 1
      assert added.teams_active == 1
      assert added.automation_rules == 1
      assert added.views_total == 1
      assert added.views_window == 1
      assert added.month_posts == 1
      assert added.month_views == 1
    end
  end

  describe "load/1 scoped to a tenant" do
    test "counts only the actor's own site" do
      %{site_a: site_a, site_b: site_b} = seed_two_sites()

      a = Overview.load(site_admin(site_a.id))
      b = Overview.load(site_admin(site_b.id))

      assert a.posts_published == 2
      assert a.posts_drafts == 1
      assert a.posts_scheduled == 1
      assert a.comments_total == 2
      assert a.bloggers_active == 1
      assert a.collections_total == 1
      assert a.tags_total == 2

      assert b.posts_published == 1
      assert b.posts_drafts == 1
      assert b.posts_scheduled == 0
      assert b.comments_total == 1
      assert b.bloggers_active == 1
      assert b.collections_total == 1
      assert b.tags_total == 1
    end

    test "scopes the join resources through the relationship that carries the site" do
      before = Overview.load(master())
      site_a = create_site!()
      site_b = create_site!()
      post_a = create_blog_post!(site_id: site_a.id)
      post_b = create_blog_post!(site_id: site_b.id)
      team_a = create_team!(site_id: site_a.id, status: :active)
      blogger_a = create_blogger!(site_id: site_a.id)
      team_b = create_team!(site_id: site_b.id, status: :active)
      blogger_b = create_blogger!(site_id: site_b.id)

      create_post_view!(post_id: post_a.id)
      create_post_view!(post_id: post_a.id)
      create_post_view!(post_id: post_b.id)
      create_post_bookmark!(post_id: post_a.id)
      create_team_member!(team_id: team_a.id, blogger_id: blogger_a.id)
      create_team_member!(team_id: team_b.id, blogger_id: blogger_b.id)

      a = Overview.load(site_admin(site_a.id))

      assert a.views_total == 2
      assert a.views_window == 2
      assert a.team_members == 1
      assert Overview.load(site_admin(site_b.id)).views_total == 1
      assert added(Overview.load(master()), before).views_total == 3
    end

    test "names the most used tag within the site and leaves it nil when no tag has a post" do
      site_a = create_site!()
      site_b = create_site!()
      post_b = create_blog_post!(site_id: site_b.id)
      create_blog_tag!(site_id: site_b.id, name: "Unused Tag")
      tag_b = create_blog_tag!(site_id: site_b.id, name: "Other Site Tag")

      assert Overview.load(site_admin(site_a.id)).tags_top == nil
      assert Overview.load(site_admin(site_b.id)).tags_top == nil

      create_post_tag!(post_id: post_b.id, tag_id: tag_b.id)

      assert Overview.load(site_admin(site_a.id)).tags_top == nil
      assert Overview.load(site_admin(site_b.id)).tags_top == "Other Site Tag"
    end
  end

  describe "load/1 with nothing to count" do
    test "returns zeros throughout without dividing by zero" do
      site = create_site!()
      other = create_site!()
      create_blog_post!(site_id: other.id, status: :published)
      create_post_view!(post_id: create_blog_post!(site_id: other.id).id)

      stats = Overview.load(site_admin(site.id))

      assert stats.engagement_rate == 0
      assert stats.engagement_previous == 0
      assert stats.month_engagement == 0
      assert stats.tags_top == nil
      assert stats.activity == []

      assert stats
             |> Map.drop([:activity, :tags_top])
             |> Map.values()
             |> Enum.all?(&(&1 == 0))
    end

    test "renders that empty scope through every presentation function" do
      site = create_site!()
      stats = Overview.load(site_admin(site.id))

      assert length(Index.kpi_cards(stats, @both)) == 5
      assert length(Index.section_cards(stats, @both)) == 8
      assert length(Index.month_rows(stats, @both)) == 4

      assert {"Engagement", _, _, "0%", "Steady vs prev. 30d", @muted} =
               Index.kpi_cards(stats, @both) |> Enum.at(4)

      assert {"Analytics", _, _, _, _, [{"Total Views", "0", _}, {"Growth Rate", "No data", _}]} =
               Index.section_cards(stats, @both) |> Enum.at(7)
    end
  end

  describe "load/1 activity" do
    test "returns the newest records of each kind as %{kind, title, at}" do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, title: "Activity Post")
      create_comment!(site_id: site.id, post_id: post.id, content: "Activity comment content")
      create_blogger!(site_id: site.id, display_name: "Activity Blogger")

      activity = Overview.load(site_admin(site.id)).activity

      assert length(activity) == 3

      for entry <- activity do
        assert %{kind: kind, title: title, at: %DateTime{}} = entry
        assert kind in [:post, :comment, :blogger]
        assert is_binary(title)
      end

      assert Enum.sort(Enum.map(activity, & &1.kind)) == [:blogger, :comment, :post]

      assert Enum.sort(Enum.map(activity, & &1.title)) ==
               ["Activity Blogger", "Activity Post", "Activity comment content"]
    end

    test "never reports another site's records" do
      site_a = create_site!()
      site_b = create_site!()
      create_blog_post!(site_id: site_b.id, title: "Foreign Post")

      assert Overview.load(site_admin(site_a.id)).activity == []

      assert Overview.load(site_admin(site_b.id)).activity |> Enum.map(& &1.title) == [
               "Foreign Post"
             ]
    end
  end

  describe "calendar/2" do
    test "returns a six-week grid with the out-of-month squares blanked" do
      site = create_site!()
      month = Date.beginning_of_month(Date.utc_today())

      %{month: read_month, cells: cells} =
        Overview.calendar(site_admin(site.id), Date.utc_today())

      assert read_month == month
      assert length(cells) == 42

      {in_month, outside} = Enum.split_with(cells, &(&1.date != nil))

      assert length(in_month) == Date.days_in_month(month)
      assert Enum.map(in_month, & &1.day) == Enum.to_list(1..Date.days_in_month(month))
      assert Enum.all?(outside, &match?(%{date: nil, day: nil, today?: false, posts: []}, &1))
    end

    test "places a published post on its published_at day and a scheduled one on its due day" do
      site = create_site!()
      published_at = DateTime.truncate(DateTime.utc_now(), :second)
      published_date = DateTime.to_date(published_at)
      scheduled_at = DateTime.add(published_at, 2, :day)
      scheduled_date = DateTime.to_date(scheduled_at)

      create_blog_post!(
        site_id: site.id,
        title: "Calendar Published",
        status: :published,
        published_at: published_at
      )

      create_blog_post!(
        site_id: site.id,
        title: "Calendar Scheduled",
        status: :scheduled,
        scheduled_publish_at: scheduled_at
      )

      published_month = Overview.calendar(site_admin(site.id), published_date)
      scheduled_month = Overview.calendar(site_admin(site.id), scheduled_date)

      assert Enum.map(Index.posts_on(published_month, published_date), & &1.title) == [
               "Calendar Published"
             ]

      assert Enum.map(Index.posts_on(scheduled_month, scheduled_date), & &1.title) == [
               "Calendar Scheduled"
             ]
    end

    test "returns a whole busy month rather than one page of it" do
      site = create_site!()
      published_at = DateTime.truncate(DateTime.utc_now(), :second)
      date = DateTime.to_date(published_at)

      for index <- 1..101 do
        create_blog_post!(
          site_id: site.id,
          title: "Busy Month #{index}",
          status: :published,
          published_at: published_at
        )
      end

      calendar = Overview.calendar(site_admin(site.id), date)

      assert length(Index.posts_on(calendar, date)) == 101
    end

    test "leaves a draft off the grid even when it carries a published_at" do
      site = create_site!()

      # Now, not a fixed hour: `published_at` must be in the past or now, so a hardcoded 08:00 fails
      # every run before 08:00 UTC. Reading the date off the same instant also cannot straddle midnight.
      published_at = DateTime.utc_now()
      today = DateTime.to_date(published_at)

      create_blog_post!(
        site_id: site.id,
        title: "Calendar Draft",
        status: :draft,
        published_at: published_at
      )

      calendar = Overview.calendar(site_admin(site.id), today)

      assert Index.posts_on(calendar, today) == []
      assert Enum.all?(calendar.cells, &(&1.posts == []))
    end

    test "never shows another site's posts" do
      site_a = create_site!()
      site_b = create_site!()
      published_at = DateTime.utc_now()
      today = DateTime.to_date(published_at)

      create_blog_post!(
        site_id: site_b.id,
        title: "Foreign Calendar Post",
        status: :published,
        published_at: published_at
      )

      assert Index.posts_on(Overview.calendar(site_admin(site_a.id), today), today) == []

      assert Overview.calendar(site_admin(site_b.id), today)
             |> Index.posts_on(today)
             |> Enum.map(& &1.title) == ["Foreign Calendar Post"]
    end

    test "marks today only on today's square" do
      site = create_site!()
      today = Date.utc_today()

      cells = Overview.calendar(site_admin(site.id), today).cells

      assert Enum.filter(cells, & &1.today?) |> Enum.map(& &1.date) == [today]
    end

    test "reads a month with no posts at all" do
      site = create_site!()
      %{cells: cells} = Overview.calendar(site_admin(site.id), ~D[1990-02-14])

      assert length(cells) == 42
      assert Enum.all?(cells, &(&1.posts == []))
      refute Enum.any?(cells, & &1.today?)
    end
  end

  describe "post_date/1" do
    test "prefers the scheduled time for a scheduled post and published_at otherwise" do
      at = ~U[2026-07-20 10:00:00Z]
      other = ~U[2026-07-11 10:00:00Z]

      assert Overview.post_date(%{status: :scheduled, scheduled_publish_at: at}) == ~D[2026-07-20]

      assert Overview.post_date(%{
               status: :published,
               published_at: other,
               scheduled_publish_at: at
             }) == ~D[2026-07-11]

      assert Overview.post_date(%{status: :draft, published_at: nil, scheduled_publish_at: at}) ==
               ~D[2026-07-20]

      assert Overview.post_date(%{status: :draft, published_at: nil, scheduled_publish_at: nil}) ==
               nil
    end
  end

  describe "compact/1" do
    test "writes counts below a thousand in full" do
      assert Index.compact(0) == "0"
      assert Index.compact(7) == "7"
      assert Index.compact(999) == "999"
    end

    test "abbreviates thousands, dropping a trailing zero tenth" do
      assert Index.compact(1_000) == "1K"
      assert Index.compact(1_049) == "1K"
      assert Index.compact(1_050) == "1.1K"
      assert Index.compact(8_429) == "8.4K"
      assert Index.compact(99_950) == "100K"
    end

    test "abbreviates millions" do
      assert Index.compact(1_000_000) == "1M"
      assert Index.compact(1_240_000) == "1.2M"
      assert Index.compact(9_950_000) == "10M"
    end

    test "carries into the next tier instead of writing a four-digit abbreviation" do
      assert Index.compact(999_499) == "999.5K"
      assert Index.compact(999_500) == "1M"
      assert Index.compact(999_499_999) == "999.5M"
      assert Index.compact(999_500_000) == "1B"
    end
  end

  describe "delta/2" do
    test "words every sign including zero" do
      assert Index.delta(5, 3) == "+2 from yesterday"
      assert Index.delta(3, 3) == "Same as yesterday"
      assert Index.delta(0, 0) == "Same as yesterday"
      assert Index.delta(1, 4) == "−3 from yesterday"
    end
  end

  describe "growth/2" do
    test "says so when there is nothing to compare to" do
      assert Index.growth(0, 0) == "No data"
      assert Index.growth(5, 0) == "New"
    end

    test "signs the percentage in both directions" do
      assert Index.growth(150, 100) == "+50%"
      assert Index.growth(50, 100) == "-50%"
      assert Index.growth(100, 100) == "0%"
      assert Index.growth(0, 100) == "-100%"
    end
  end

  describe "move_tone/2" do
    test "is green up, red down and muted flat" do
      assert Index.move_tone(2, 1) == @up
      assert Index.move_tone(1, 2) == @down
      assert Index.move_tone(1, 1) == @muted
      assert Index.move_tone(0, 0) == @muted
    end
  end

  describe "month_label/1 and day_label/1" do
    test "spell the month out and abbreviate it in the sidebar" do
      assert Index.month_label(~D[2026-07-20]) == "July 2026"
      assert Index.month_label(~D[2026-01-01]) == "January 2026"
      assert Index.month_label(~D[2026-12-31]) == "December 2026"

      assert Index.day_label(~D[2026-07-20]) == "Monday, Jul 20"
      assert Index.day_label(~D[2026-07-19]) == "Sunday, Jul 19"
      assert Index.day_label(~D[2026-01-03]) == "Saturday, Jan 3"
    end
  end

  describe "posts_on/2" do
    test "yields nothing for an unloaded calendar or a day with no posts" do
      assert Index.posts_on(nil, ~D[2026-07-20]) == []

      calendar = %{
        month: ~D[2026-07-01],
        cells: [
          %{date: nil, day: nil, today?: false, posts: []},
          %{date: ~D[2026-07-01], day: 1, today?: false, posts: []},
          %{date: ~D[2026-07-02], day: 2, today?: false, posts: [%{title: "One"}]}
        ]
      }

      assert Index.posts_on(calendar, ~D[2026-07-01]) == []
      assert Index.posts_on(calendar, ~D[2026-07-31]) == []
      assert Index.posts_on(calendar, ~D[2026-07-02]) == [%{title: "One"}]
    end
  end

  describe "post_time/1" do
    test "labels a scheduled post and falls back to an em dash" do
      at = ~U[2026-07-20 14:05:00Z]

      assert Index.post_time(%{status: :scheduled, scheduled_publish_at: at}) ==
               "Scheduled · 14:05"

      assert Index.post_time(%{status: :published, published_at: at}) == "14:05"
      assert Index.post_time(%{status: :draft, published_at: nil}) == "—"
      assert Index.post_time(%{}) == "—"
    end
  end

  describe "status_tone/1 and cell_tone/2" do
    test "gives each status its own chip and never repeats one" do
      tones = Enum.map([:published, :scheduled, :draft], &Index.status_tone/1)

      assert Enum.uniq(tones) == tones
      assert Index.status_tone(:archived) == Index.status_tone(:anything_else)
      refute Index.status_tone(:archived) in tones
    end

    test "fills a square by whether it is outside, selected, today or ordinary" do
      selected = ~D[2026-07-20]
      outside = %{date: nil, day: nil, today?: false, posts: []}
      chosen = %{date: selected, day: 20, today?: false, posts: []}
      today = %{date: ~D[2026-07-21], day: 21, today?: true, posts: []}
      plain = %{date: ~D[2026-07-22], day: 22, today?: false, posts: []}

      assert Index.cell_tone(outside, selected) == "bg-[#faf9f6]"
      assert Index.cell_tone(chosen, selected) == "bg-[#f2f1fc] ring-1 ring-inset ring-[#dcdbf5]"
      assert Index.cell_tone(today, selected) == "bg-[#e6f6ee]"
      assert Index.cell_tone(plain, selected) == "bg-white hover:bg-[#f7f6f3]"
    end

    test "prefers the selection over today when they are the same square" do
      date = ~D[2026-07-20]
      cell = %{date: date, day: 20, today?: true, posts: []}

      assert Index.cell_tone(cell, date) == "bg-[#f2f1fc] ring-1 ring-inset ring-[#dcdbf5]"
    end
  end

  describe "activity_tone/1 and activity_label/2" do
    test "give each of the three kinds load/1 emits its own dot" do
      kinds = [:post, :comment, :blogger]

      assert Enum.map(kinds, &Index.activity_tone/1) |> Enum.uniq() |> length() == 3
    end

    test "word a post from its status so a draft is never announced as published" do
      assert Index.activity_label(:post, :published) == "New post published"
      assert Index.activity_label(:post, :draft) == "New draft created"
      assert Index.activity_label(:post, :scheduled) == "New post scheduled"
      assert Index.activity_label(:post, :archived) == "New post added"
      assert Index.activity_label(:comment, :pending) == "New comment posted"
      assert Index.activity_label(:blogger, nil) == "New blogger joined"
    end

    test "load/1 carries the status the label is worded from" do
      site = create_site!()
      create_blog_post!(site_id: site.id, title: "Draft Feed Entry", status: :draft)

      entry =
        Overview.load(site_admin(site.id)).activity
        |> Enum.find(&(&1.kind == :post))

      assert entry.title == "Draft Feed Entry"
      assert entry.status == :draft
      assert Index.activity_label(entry.kind, entry.status) == "New draft created"
    end
  end

  describe "day_count_label/1" do
    test "pluralises the calendar sidebar count" do
      assert Index.day_count_label(0) == "0 posts on this day"
      assert Index.day_count_label(1) == "1 post on this day"
      assert Index.day_count_label(5) == "5 posts on this day"
    end
  end

  describe "ago/1" do
    test "steps up a unit at each boundary" do
      now = DateTime.utc_now()
      back = &DateTime.add(now, -&1, :second)

      assert Index.ago(back.(0)) == "just now"
      assert Index.ago(back.(59)) == "just now"
      assert Index.ago(back.(60)) == "1 minute ago"
      assert Index.ago(back.(120)) == "2 minutes ago"
      assert Index.ago(back.(3_599)) == "59 minutes ago"
      assert Index.ago(back.(3_600)) == "1 hour ago"
      assert Index.ago(back.(86_399)) == "23 hours ago"
      assert Index.ago(back.(86_400)) == "1 day ago"
      assert Index.ago(back.(2_591_999)) == "29 days ago"
    end

    test "falls back to a date once it is over a month old" do
      at = DateTime.add(DateTime.utc_now(), -2_592_000, :second)

      assert Index.ago(at) == Calendar.strftime(at, "%b %d, %Y")
    end

    test "reads a future timestamp as just now rather than a negative age" do
      assert Index.ago(DateTime.add(DateTime.utc_now(), 3_600, :second)) == "just now"
    end
  end

  describe "kpi_cards/2" do
    test "the loading clause matches the loaded one in arity and shape" do
      blank = Index.kpi_cards(nil, @both)
      loaded = Index.kpi_cards(Overview.load(master()), @both)

      assert length(blank) == 5
      assert length(loaded) == length(blank)

      for {label, icon, tone, value, note, note_tone} <- blank do
        assert is_binary(label) and is_binary(icon) and is_binary(tone)
        assert value == "—"
        assert note == "…"
        assert note_tone == @waiting
      end

      assert Enum.map(blank, &elem(&1, 0)) == Enum.map(loaded, &elem(&1, 0))
      assert Enum.map(blank, &elem(&1, 1)) == Enum.map(loaded, &elem(&1, 1))
      assert Enum.all?(loaded, fn card -> tuple_size(card) == 6 end)
    end

    test "reads the loaded numbers into values and notes" do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, status: :published)
      create_comment!(site_id: site.id, post_id: post.id)
      create_blogger!(site_id: site.id)

      cards = Index.kpi_cards(Overview.load(site_admin(site.id)), @both)

      assert {"Today's Posts", _, _, "1", "+1 from yesterday", @up} = Enum.at(cards, 0)
      assert {"Today's Views", _, _, "0", "No views yet today", @muted} = Enum.at(cards, 1)
      assert {"New Comments", _, _, "1", "1 pending review", _} = Enum.at(cards, 2)
      assert {"Active Bloggers", _, _, "1", "1 joined this month", @muted} = Enum.at(cards, 3)
      assert {"Engagement", _, _, "0%", "Steady vs prev. 30d", @muted} = Enum.at(cards, 4)
    end
  end

  describe "section_cards/2" do
    test "the loading clause matches the loaded one in arity and shape" do
      blank = Index.section_cards(nil, @both)
      loaded = Index.section_cards(Overview.load(master()), @both)

      assert length(blank) == 8
      assert length(loaded) == length(blank)

      for {title, description, link, icon, tone, rows} <- blank do
        assert is_binary(title) and is_binary(description) and is_binary(icon) and is_binary(tone)
        assert String.starts_with?(link, "/admin/dashboard/blog")
        assert [{first, "—", @waiting}, {second, "—", @waiting}] = rows
        assert is_binary(first) and is_binary(second)
      end

      assert Enum.map(blank, &elem(&1, 0)) == Enum.map(loaded, &elem(&1, 0))
      assert Enum.map(blank, &elem(&1, 2)) == Enum.map(loaded, &elem(&1, 2))

      for {_, _, _, _, _, rows} <- loaded do
        assert [{_, value, _}, {_, other, _}] = rows
        assert is_binary(value) and is_binary(other)
      end
    end

    test "a site with no tagged post shows an em dash rather than a blank" do
      site = create_site!()

      assert [{"Total Tags", "0", _}, {"Most Used", "—", _}] =
               Index.section_cards(Overview.load(site_admin(site.id)), @both)
               |> Enum.at(6)
               |> elem(5)
    end

    test "reads the loaded numbers into both rows of every card" do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, status: :published)
      collection = create_collection!(site_id: site.id, status: :active)
      create_post_collection!(post_id: post.id, collection_id: collection.id)

      cards = Index.section_cards(Overview.load(site_admin(site.id)), @both)

      assert {"Collections", _, _, _, _,
              [{"Total Collections", "1", _}, {"Posts Organized", "1", _}]} =
               Enum.at(cards, 0)

      assert {"Blog Posts", _, _, _, _, [{"Published", "1", _}, {"Drafts", "0", _}]} =
               Enum.at(cards, 1)
    end
  end

  describe "month_rows/2" do
    test "the loading clause matches the loaded one in arity and shape" do
      blank = Index.month_rows(nil, @both)
      loaded = Index.month_rows(Overview.load(master()), @both)

      assert length(blank) == 4
      assert length(loaded) == length(blank)
      assert Enum.map(blank, &elem(&1, 0)) == Enum.map(loaded, &elem(&1, 0))
      assert Enum.all?(blank, &match?({_, "—", @waiting}, &1))
      assert Enum.all?(loaded, fn {_, value, tone} -> is_binary(value) and is_binary(tone) end)
    end

    test "renders the engagement row as a percentage" do
      site = create_site!()

      assert {"Engagement Rate", "0%", @up} =
               Index.month_rows(Overview.load(site_admin(site.id)), @both) |> Enum.at(3)
    end

    test "reads this month's counts" do
      site = create_site!()
      create_blog_post!(site_id: site.id, status: :published)

      assert [{"Posts Published", "1", @body} | _] =
               Index.month_rows(Overview.load(site_admin(site.id)), @both)
    end
  end

  describe "quick_actions/1" do
    test "lists four admin destinations with exactly one primary" do
      actions = Index.quick_actions(@both)

      assert length(actions) == 4
      assert Enum.count(actions, fn {_, _, _, primary?} -> primary? end) == 1

      for {label, icon, path, primary?} <- actions do
        assert is_binary(label) and is_binary(icon)
        assert String.starts_with?(path, "/admin/dashboard/")
        assert is_boolean(primary?)
      end
    end
  end

  # EACH FIGURE IS READ FROM THE AREA IT BELONGS TO: a moderator's overview reads no post, view or
  # blogger, an editor's no comment, and the engagement rate — comments over views — needs both.
  describe "load/1 and calendar/2 by area" do
    setup do
      site = create_site!()
      post = create_blog_post!(site_id: site.id, status: :published)
      create_blog_post!(site_id: site.id, status: :draft)
      create_comment!(site_id: site.id, post_id: post.id, status: :pending)
      create_blogger!(site_id: site.id)
      create_post_view!(post_id: post.id)

      %{site: site}
    end

    test "a moderator's figures are the comments alone", %{site: site} do
      stats = Overview.load(site_admin(site.id, ["admin:dashboard:blog:comment"]))

      assert stats.comments_total == 1
      assert stats.comments_pending == 1
      assert stats.posts_published == 0
      assert stats.posts_drafts == 0
      assert stats.bloggers_active == 0
      assert stats.views_total == 0
      assert stats.engagement_rate == 0
      assert Enum.map(stats.activity, & &1.kind) == [:comment]

      assert Overview.calendar(
               site_admin(site.id, ["admin:dashboard:blog:comment"]),
               Date.utc_today()
             ).cells
             |> Enum.flat_map(& &1.posts) == []
    end

    test "an editor's figures are the posts alone", %{site: site} do
      editor = site_admin(site.id, ["admin:dashboard:blog:post"])
      stats = Overview.load(editor)

      assert stats.posts_published == 1
      assert stats.posts_drafts == 1
      assert stats.bloggers_active == 1
      assert stats.views_total == 1
      assert stats.comments_total == 0
      assert stats.comments_pending == 0
      assert stats.month_comments == 0
      assert stats.engagement_rate == 0
      refute Enum.any?(stats.activity, &(&1.kind == :comment))

      assert Overview.calendar(editor, Date.utc_today()).cells |> Enum.flat_map(& &1.posts) != []
    end

    test "a holder of neither reads nothing", %{site: site} do
      stats = Overview.load(site_admin(site.id, ["admin:dashboard:runtime:page"]))

      assert stats |> Map.drop([:activity, :tags_top]) |> Map.values() |> Enum.all?(&(&1 == 0))
      assert stats.activity == []
    end
  end

  describe "the cards by area" do
    @moderator %{post: false, comment: true}
    @editor %{post: true, comment: false}

    defp labels(cards), do: Enum.map(cards, &elem(&1, 0))

    test "a moderator is drawn the comments' cards, rows and links alone" do
      assert labels(Index.kpi_cards(nil, @moderator)) == ["New Comments"]
      assert labels(Index.section_cards(nil, @moderator)) == ["Comments"]
      assert labels(Index.month_rows(nil, @moderator)) == ["New Comments"]
      assert labels(Index.quick_actions(@moderator)) == ["Review Comments", "Blog Settings"]
    end

    test "an editor is drawn every card but the comments' and the engagement" do
      assert labels(Index.kpi_cards(nil, @editor)) ==
               ["Today's Posts", "Today's Views", "Active Bloggers"]

      assert "Comments" not in labels(Index.section_cards(nil, @editor))
      assert length(Index.section_cards(nil, @editor)) == 7
      assert labels(Index.month_rows(nil, @editor)) == ["Posts Published", "Total Views"]

      assert labels(Index.quick_actions(@editor)) ==
               ["Create New Post", "View Analytics", "Blog Settings"]
    end

    test "the engagement figures are a holder of both's" do
      assert "Engagement" in labels(Index.kpi_cards(nil, @both))
      assert "Engagement Rate" in labels(Index.month_rows(nil, @both))
    end
  end

  defp added(after_load, before_load) do
    for {key, value} <- after_load, is_integer(value), into: %{} do
      {key, value - Map.fetch!(before_load, key)}
    end
  end

  defp seed_two_sites do
    site_a = create_site!()
    site_b = create_site!()

    post_a = create_blog_post!(site_id: site_a.id, status: :published)
    create_blog_post!(site_id: site_a.id, status: :published)
    create_blog_post!(site_id: site_a.id, status: :draft)

    create_blog_post!(
      site_id: site_a.id,
      status: :scheduled,
      scheduled_publish_at:
        DateTime.add(DateTime.utc_now(), 2, :day) |> DateTime.truncate(:second)
    )

    post_b = create_blog_post!(site_id: site_b.id, status: :published)
    create_blog_post!(site_id: site_b.id, status: :draft)

    create_comment!(site_id: site_a.id, post_id: post_a.id)
    create_comment!(site_id: site_a.id, post_id: post_a.id)
    create_comment!(site_id: site_b.id, post_id: post_b.id)

    create_blogger!(site_id: site_a.id)
    create_blogger!(site_id: site_b.id)

    create_collection!(site_id: site_a.id, status: :active)
    create_collection!(site_id: site_b.id, status: :active)

    create_blog_tag!(site_id: site_a.id)
    create_blog_tag!(site_id: site_a.id)
    create_blog_tag!(site_id: site_b.id)

    %{site_a: site_a, site_b: site_b}
  end

  describe "areas/1" do
    for {names, areas} <- [
          {[], %{post: false, comment: false}},
          {["admin:dashboard:blog:post"], %{post: true, comment: false}},
          {["admin:dashboard:blog:comment"], %{post: false, comment: true}},
          {["admin:dashboard:blog:*"], %{post: true, comment: true}},
          {["admin:dashboard:*"], %{post: true, comment: true}},
          {["*"], %{post: true, comment: true}},
          {["admin:api:*"], %{post: false, comment: false}},
          {["admin:api:blog:post"], %{post: false, comment: false}},
          {["admin:dashboard:runtime:page"], %{post: false, comment: false}}
        ] do
      test "#{inspect(names)} holds #{inspect(areas)}" do
        user = create_user_with_permissions!(unquote(names))

        assert Overview.areas(user) == unquote(Macro.escape(areas))
      end
    end

    test "nobody holds neither" do
      assert Overview.areas(nil) == %{post: false, comment: false}
    end
  end
end
