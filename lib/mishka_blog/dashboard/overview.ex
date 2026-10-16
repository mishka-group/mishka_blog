# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Overview do
  @moduledoc """
  Every number on the blog admin overview page (`/admin/dashboard/blog`), read from the database.

  `load/1` gathers the whole page in one pass — the five KPI cards, the eight section cards, the
  "This Month" panel and the recent-activity list — and `calendar/2` reads one month of the editorial
  calendar. Both are pure reads returning plain numbers and records; every label, delta and
  abbreviation is the page's business, not this module's.

  Scoping follows the dashboard widgets: `MishkaCmsCore.Dashboard.Widget.scope/1` turns the viewer
  into either `nil` (a master, who counts every site) or a site id (a tenant admin, who counts only
  theirs), and every query goes through a `:master_read` with `authorize?: false`. The two join
  resources — `MishkaBlog.PostView` and `MishkaBlog.TeamMember` — carry no `site_id` of their own,
  so they are scoped through the relationship that does. Their master clauses still join that
  relationship (`not is_nil(post.id)`) even though they need no site condition: the join carries the
  destination's own archival filter, and a master counting rows a tenant cannot see would make the
  same site read differently depending on who is looking at it.

  ## What a viewer's figures are read from

  Each figure is read only from the blog area the viewer holds (`areas/1`): posts, views, bloggers,
  collections, tags, teams and auto posting from `admin:dashboard:blog:post`, comments from
  `admin:dashboard:blog:comment`. A table of an area the viewer does not hold is read as empty, so its counts are
  zero, its rows are missing from `:activity`, and an engagement rate — comments over views — is
  zero unless both are held. The calendar is a post holder's.

  Counts are deliberately many small `Ash.count!/2` calls rather than one hand-written query: each
  one goes through the resource's own read action, so archival, base filters and multitenancy stay
  the resources' business. The caller is expected to run this off the render — see
  `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index`, which loads it in a `start_async/3`.

  See `MishkaBlog.Dashboard.Widgets.DraftsScheduled` for the same idiom at widget scale.
  """
  require Ash.Query

  alias MishkaBlog.AutoPosting
  alias MishkaBlog.Blogger
  alias MishkaBlog.BlogPost
  alias MishkaBlog.Collection
  alias MishkaBlog.Comment
  alias MishkaBlog.PostView
  alias MishkaBlog.Tag
  alias MishkaBlog.Team
  alias MishkaBlog.TeamMember
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Dashboard.Widget

  @recent_days 7
  @window_days 30
  @activity_limit 4
  @per_kind 2

  @typedoc "Which blog areas a viewer holds on the dashboard."
  @type areas :: %{post: boolean(), comment: boolean()}

  @doc """
  Which blog areas `user` holds on the dashboard: `:post` for `admin:dashboard:blog:post`,
  `:comment` for `admin:dashboard:blog:comment`. `nil`, or a user holding neither, holds none.
  """
  @spec areas(map() | nil) :: areas()
  def areas(user) do
    user = AccessPermissions.with_permissions(user)

    %{
      post: AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:blog:post"]),
      comment: AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:blog:comment"])
    }
  end

  @doc """
  Reads every statistic the overview page shows, scoped to `user`.

  Returns a flat map of numbers plus `:activity`, the newest few blog records as
  `%{kind, title, status, at}` — `kind` being `:post`, `:comment` or `:blogger`, and `status` the
  record's own status where it has one (`nil` for a blogger) so the page can word the entry without
  claiming a draft was published.
  """
  @spec load(map() | nil) :: map()
  def load(user) do
    scope = {Widget.scope(user), areas(user)}
    today = Date.utc_today()
    now = DateTime.utc_now()
    month_start = beginning_of_day(Date.beginning_of_month(today))
    window_start = DateTime.add(now, -@window_days, :day)
    previous_start = DateTime.add(now, -2 * @window_days, :day)

    posts = posts_base(scope)
    comments = comments_base(scope)
    views = views_base(scope)

    views_window = count(between(views, window_start, now))
    views_previous = count(between(views, previous_start, window_start))
    month_views = count(since(views, month_start))
    month_comments = count(since(comments, month_start))

    %{
      posts_today: count(on_day(posts, today)),
      posts_yesterday: count(on_day(posts, Date.add(today, -1))),
      views_today: count(on_day(views, today)),
      views_yesterday: count(on_day(views, Date.add(today, -1))),
      comments_recent: count(since(comments, DateTime.add(now, -@recent_days, :day))),
      comments_pending: count(pending(comments)),
      comments_total: count(comments),
      bloggers_active: count(bloggers_base(scope)),
      bloggers_new: count(since(bloggers_base(scope), month_start)),
      bloggers_publishers: count(publishers(bloggers_base(scope))),
      engagement_rate: rate(count(between(comments, window_start, now)), views_window),
      engagement_previous:
        rate(count(between(comments, previous_start, window_start)), views_previous),
      collections_total: count(collections_base(scope)),
      posts_organised: count(in_a_collection(posts)),
      posts_published: count(with_status(posts, :published)),
      posts_drafts: count(with_status(posts, :draft)),
      posts_scheduled: count(with_status(posts, :scheduled)),
      teams_active: count(active_teams(scope)),
      team_members: count(members_base(scope)),
      automation_rules: count(active_rules(scope)),
      tags_total: count(tags_base(scope)),
      tags_top: top_tag(scope),
      views_total: count(views),
      views_window: views_window,
      views_previous: views_previous,
      month_posts: count(published_since(with_status(posts, :published), month_start)),
      month_views: month_views,
      month_comments: month_comments,
      month_engagement: rate(month_comments, month_views),
      activity: activity(scope)
    }
  end

  @doc """
  Reads the editorial calendar for the month containing `date`, scoped to `user`.

  Returns `%{month: Date.t(), cells: [cell]}` where the cells are the 42 squares of a six-week grid.
  A cell outside the month carries `date: nil` and no posts; an in-month cell carries the published
  posts whose `published_at` and the scheduled posts whose `scheduled_publish_at` land on that day.

  Only those two states appear: a draft has no place on an editorial calendar even when it carries a
  leftover `published_at`, and an archived post has already left it.
  """
  @spec calendar(map() | nil, Date.t()) :: map()
  def calendar(user, date) do
    month = Date.beginning_of_month(date)
    from = beginning_of_day(month)
    to = beginning_of_day(Date.add(Date.end_of_month(month), 1))

    by_day =
      {Widget.scope(user), areas(user)}
      |> calendar_base()
      |> Ash.Query.filter(
        (status == :published and published_at >= ^from and published_at < ^to) or
          (status == :scheduled and scheduled_publish_at >= ^from and
             scheduled_publish_at < ^to)
      )
      |> Ash.Query.select([:id, :title, :status, :published_at, :scheduled_publish_at, :language])
      |> Ash.Query.sort(published_at: :asc, scheduled_publish_at: :asc)
      |> Ash.read!(page: false, authorize?: false)
      |> Enum.group_by(&post_date/1)

    %{month: month, cells: cells(month, by_day)}
  end

  @doc "The day a post belongs on in the calendar — when it went out, or when it is due to."
  @spec post_date(map()) :: Date.t() | nil
  def post_date(%{status: :scheduled, scheduled_publish_at: %DateTime{} = at}),
    do: DateTime.to_date(at)

  def post_date(%{published_at: %DateTime{} = at}), do: DateTime.to_date(at)
  def post_date(%{scheduled_publish_at: %DateTime{} = at}), do: DateTime.to_date(at)
  def post_date(_post), do: nil

  defp cells(month, by_day) do
    today = Date.utc_today()
    days = Date.days_in_month(month)
    offset = Date.day_of_week(month, :sunday) - 1

    Enum.map(0..41, fn index ->
      cell(index - offset + 1, days, month, today, by_day)
    end)
  end

  defp cell(day, days, _month, _today, _by_day) when day < 1 or day > days do
    %{date: nil, day: nil, today?: false, posts: []}
  end

  defp cell(day, _days, month, today, by_day) do
    date = Date.new!(month.year, month.month, day)

    %{
      date: date,
      day: day,
      today?: date == today,
      posts: Map.get(by_day, date, [])
    }
  end

  # Two per kind rather than the newest four outright: a seeding run — or a busy comment thread —
  # lands a dozen rows of one kind within the same second, and a feed showing nothing but comments
  # says less about the blog than one showing a post, a comment and a new author.
  defp activity(scope) do
    [
      {:post, newest(posts_base(scope))},
      {:comment, newest(comments_base(scope))},
      {:blogger, newest(bloggers_base(scope))}
    ]
    |> Enum.flat_map(fn {kind, records} ->
      Enum.map(
        records,
        &%{
          kind: kind,
          title: activity_title(kind, &1),
          status: Map.get(&1, :status),
          at: &1.inserted_at
        }
      )
    end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(@activity_limit)
  end

  defp newest(query) do
    query
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(page: [limit: @per_kind], authorize?: false)
    |> Map.fetch!(:results)
  end

  defp activity_title(:post, post), do: post.title
  defp activity_title(:blogger, blogger), do: blogger.display_name

  defp activity_title(:comment, comment) do
    comment.content
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp top_tag(scope) do
    scope
    |> tags_base()
    |> Ash.Query.load(:post_count)
    |> Ash.Query.sort(post_count: :desc, name: :asc)
    |> Ash.read!(page: [limit: 1], authorize?: false)
    |> Map.fetch!(:results)
    |> List.first()
    |> tag_name()
  end

  defp tag_name(%{post_count: 0}), do: nil
  defp tag_name(%{name: name}), do: name
  defp tag_name(nil), do: nil

  defp posts_base(scope),
    do:
      BlogPost
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> by_site(scope, :post)

  # `:read_any` rather than `:master_read` because a month is bounded by the calendar, not by a page:
  # only `:read_any` sets `required?: false`, so only it accepts `page: false`. `:master_read` caps at
  # `max_page_size: 100`, which would have silently dropped the tail of a busy month.
  defp calendar_base(scope),
    do: BlogPost |> Ash.Query.for_read(:read_any) |> by_site(scope, :post)

  defp comments_base(scope),
    do:
      Comment
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> by_site(scope, :comment)

  defp bloggers_base(scope),
    do:
      Blogger |> Ash.Query.for_read(:master_read, %{}, authorize?: false) |> by_site(scope, :post)

  defp collections_base(scope),
    do:
      Collection
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> by_site(scope, :post)

  defp tags_base(scope),
    do: Tag |> Ash.Query.for_read(:master_read, %{}, authorize?: false) |> by_site(scope, :post)

  # The viewer's site, and nothing of an area it does not hold.
  defp by_site(query, {site_id, areas}, area), do: query |> held(areas, area) |> by_site(site_id)

  defp by_site(query, nil), do: query
  defp by_site(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp views_base({nil, areas}),
    do:
      PostView
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(not is_nil(post.id))
      |> held(areas, :post)

  defp views_base({site_id, areas}),
    do:
      PostView
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(post.site_id == ^site_id)
      |> held(areas, :post)

  defp members_base({nil, areas}),
    do:
      TeamMember
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(not is_nil(team.id))
      |> held(areas, :post)

  defp members_base({site_id, areas}),
    do:
      TeamMember
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(team.site_id == ^site_id)
      |> held(areas, :post)

  defp held(query, areas, area) do
    case Map.get(areas, area, false) do
      true -> query
      false -> Ash.Query.filter(query, false)
    end
  end

  defp active_teams(scope) do
    Team
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> by_site(scope, :post)
    |> Ash.Query.filter(status == :active)
  end

  defp active_rules(scope) do
    AutoPosting
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> by_site(scope, :post)
    |> Ash.Query.filter(is_active == true)
  end

  defp with_status(query, status), do: Ash.Query.filter(query, status == ^status)
  defp pending(query), do: Ash.Query.filter(query, status == :pending)
  defp publishers(query), do: Ash.Query.filter(query, can_publish_directly == true)
  defp in_a_collection(query), do: Ash.Query.filter(query, collection_count > 0)
  defp since(query, from), do: Ash.Query.filter(query, inserted_at >= ^from)
  defp published_since(query, from), do: Ash.Query.filter(query, published_at >= ^from)

  defp between(query, from, to),
    do: Ash.Query.filter(query, inserted_at >= ^from and inserted_at < ^to)

  defp on_day(query, date) do
    between(query, beginning_of_day(date), beginning_of_day(Date.add(date, 1)))
  end

  defp beginning_of_day(date), do: DateTime.new!(date, ~T[00:00:00])

  defp rate(_interactions, 0), do: 0
  defp rate(interactions, views), do: round(interactions * 100 / views)

  defp count(query), do: Ash.count!(query, authorize?: false)
end
