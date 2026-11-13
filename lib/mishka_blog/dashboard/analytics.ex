# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Analytics do
  @moduledoc """
  Every number on the blog analytics page (`/admin/dashboard/blog/analytics`), read from the database.

  `load/2` reads one window — seven, thirty or ninety whole days ending today — and returns the KPI
  figures, the daily views series and the posts read most in that window, from
  `MishkaBlog.PostViewDaily`: one row per post and day with its views and unique readers. Nothing is
  estimated, which is why there is no read time and no bounce rate: nothing observes a reader leaving.

  A reader is counted once a day for each post they read (`MishkaBlog.Views`), so "Unique Readers" is
  the sum of those, and approximate where the site runs on several nodes, each telling its readers
  apart on its own. Views are written within a minute of being counted.

  Every figure is read as `user` through `MishkaBlog.Dashboard.Scope`, as
  `MishkaBlog.Dashboard.Overview` reads its own: a master (a user whose `site_id` is nil) counts every
  site, a site user only its own. A day's row is joined to its post (`not is_nil(post.id)`), so the
  views of an archived post are not counted.

  The window's rows are read once — four selected columns — and the series, the readers and the top
  posts are folded out of them in memory, as an Ash read does not `GROUP BY`. The all-time and
  previous-window totals are one `SUM` each (`Scope.sum/2`).

  Views and posts are read only for a holder of `admin:dashboard:blog:post`, and comments only for a
  holder of `admin:dashboard:blog:comment` (`MishkaBlog.Dashboard.Overview.areas/1`) — the
  permissions those resources' policies ask for. A read of an area the viewer does not hold is
  refused and counted as no data, so its figures are zero and an engagement rate needs both.

  The caller runs this off the render — see `MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index`.
  """
  require Ash.Query

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Comment
  alias MishkaBlog.Dashboard.Figures
  alias MishkaBlog.Dashboard.Scope
  alias MishkaBlog.PostViewDaily

  @ranges [7, 30, 90]
  @default_days 30
  @top_posts 5

  @doc "The windows the page offers, in whole days."
  @spec ranges() :: [pos_integer()]
  def ranges, do: @ranges

  @doc "The window the page opens on, in whole days."
  @spec default_days() :: pos_integer()
  def default_days, do: @default_days

  @doc """
  Reads the analytics page for the last `days` days, as `user` (see `MishkaBlog.Dashboard.Scope`).

  Returns a flat map: the all-time and windowed view totals, the window before it to compare
  against, today and yesterday, the readers behind the window, the comment engagement rate, and two
  collections — `:series` (one `%{date, count}` per day of the window, zeros included) and
  `:top_posts` (`%{title, status, published_at, views}`, most read first).

  `:from` and `:to` are the window's own bounds, so the page can say which days it is describing
  rather than assuming they match the `days` it asked for.
  """
  @spec load(map(), pos_integer()) :: map()
  def load(user, days \\ @default_days) when days > 0 do
    today = Date.utc_today()
    from = Date.add(today, -(days - 1))
    previous_from = Date.add(from, -days)
    previous_to = Date.add(from, -1)

    views = views_base(user)
    comments = Scope.query(Comment, user)

    rows = window_rows(views, from, today)

    by_day =
      rows
      |> Enum.group_by(& &1.day, & &1.views)
      |> Map.new(fn {day, v} -> {day, Enum.sum(v)} end)

    daily = series(by_day, from, days)
    views_window = Enum.sum_by(rows, & &1.views)
    views_previous = views |> in_days(previous_from, previous_to) |> Scope.sum(:views)
    comments_window = count(comments_in_days(comments, from, today))

    %{
      days: days,
      from: from,
      to: today,
      views_total: Scope.sum(views, :views),
      views_window: views_window,
      views_previous: views_previous,
      views_today: Map.get(by_day, today, 0),
      views_yesterday: Map.get(by_day, Date.add(today, -1), 0),
      visitors: Enum.sum_by(rows, & &1.unique_readers),
      comments_window: comments_window,
      engagement_rate: Figures.rate(comments_window, views_window),
      engagement_previous:
        Figures.rate(
          count(comments_in_days(comments, previous_from, previous_to)),
          views_previous
        ),
      series: daily,
      peak: Enum.max_by(daily, & &1.count),
      top_posts: top_posts(rows, user)
    }
  end

  defp window_rows(views, from, to) do
    views
    |> in_days(from, to)
    |> Ash.Query.select([:day, :views, :unique_readers, :post_id])
    |> Scope.list()
  end

  # Every day of the window is emitted, including the empty ones: a line drawn only through the days
  # that happened to have a view would space a quiet week the same as a busy one.
  defp series(by_day, from, days) do
    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(from, offset)

      %{date: date, count: Map.get(by_day, date, 0)}
    end)
  end

  defp top_posts(rows, user) do
    rows
    |> Enum.group_by(& &1.post_id, & &1.views)
    |> Enum.map(fn {id, views} -> {id, Enum.sum(views)} end)
    |> Enum.sort_by(fn {_id, views} -> -views end)
    |> Enum.take(@top_posts)
    |> with_titles(user)
  end

  defp with_titles([], _user), do: []

  # A post the viewer cannot read simply drops out of the ranking rather than appearing as an
  # untitled row: the counts came from views the viewer may read, the titles must come from posts it
  # may read too.
  defp with_titles(counted, user) do
    views = Map.new(counted)

    BlogPost
    |> Scope.query(user)
    |> Ash.Query.filter(id in ^Map.keys(views))
    |> Ash.Query.select([:id, :title, :status, :published_at])
    |> Scope.list(map_size(views))
    |> Enum.map(
      &%{
        title: &1.title,
        status: &1.status,
        published_at: &1.published_at,
        views: Map.fetch!(views, &1.id)
      }
    )
    |> Enum.sort_by(&{-&1.views, &1.title})
  end

  defp views_base(user),
    do: PostViewDaily |> Scope.query(user) |> Ash.Query.filter(not is_nil(post.id))

  defp in_days(query, from, to), do: Ash.Query.filter(query, day >= ^from and day <= ^to)

  defp comments_in_days(query, from, to) do
    Ash.Query.filter(
      query,
      inserted_at >= ^Figures.beginning_of_day(from) and
        inserted_at < ^Figures.beginning_of_day(Date.add(to, 1))
    )
  end

  defp count(query), do: Scope.count(query)
end
