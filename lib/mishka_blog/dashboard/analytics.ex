# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Analytics do
  @moduledoc """
  Every number on the blog analytics page (`/admin/dashboard/blog/analytics`), read from the database.

  `load/2` reads one window — seven, thirty or ninety whole days ending today — and returns the KPI
  figures, the daily views series, the posts read most in that window, where their readers came from
  and whether those readers were signed in. Nothing is estimated: the page carries a metric only
  where `MishkaBlog.PostView` actually records one, which is why there is no read time, no session
  length and no bounce rate — nothing in the schema observes a reader leaving.

  A view row is written once per post per reader (per account when signed in, per IP otherwise) and
  never updated, so "views" here means *distinct readers who opened a post*, and `inserted_at` is the
  first time each one did. That is the unit every figure below is in.

  Scoping is `MishkaBlog.Dashboard.Overview`'s: `MishkaCmsCore.Dashboard.Widget.scope/1` turns the
  viewer into `nil` (a master, counting every site) or a site id (a tenant admin, counting only
  theirs), `MishkaBlog.PostView` carries no `site_id` of its own so it is scoped through its post, and
  every query runs `authorize?: false` through the resource's own read action.

  The window is read once — five selected columns over one `Ash.read!/2` — and the series, the reader
  count, the referrers, the audience split and the top posts are folded out of those rows in memory.
  Each of those panels is a `GROUP BY` that an Ash read does not express, and one narrow read beats
  five hand-written queries. The all-time and previous-window totals stay `Ash.count!/2` calls, as
  they are single numbers.

  Views and posts are read only for a holder of `admin:dashboard:blog:post`, and comments only for a
  holder of `admin:dashboard:blog:comment` (`MishkaBlog.Dashboard.Overview.areas/1`); an area the
  viewer does not hold is read as empty, so its figures are zero and an engagement rate needs both.

  The caller runs this off the render — see `MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index`.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Comment
  alias MishkaBlog.PostView
  alias MishkaCmsCore.Dashboard.Widget

  @ranges [7, 30, 90]
  @default_days 30
  @top_posts 5
  @top_referrers 6

  @doc "The windows the page offers, in whole days."
  @spec ranges() :: [pos_integer()]
  def ranges, do: @ranges

  @doc "The window the page opens on, in whole days."
  @spec default_days() :: pos_integer()
  def default_days, do: @default_days

  @doc """
  Reads the analytics page for the last `days` days, scoped to `user`.

  Returns a flat map: the all-time and windowed view totals, the window before it to compare
  against, today and yesterday, the distinct readers behind them, the comment engagement rate, and
  four collections — `:series` (one `%{date, count}` per day of the window, zeros included),
  `:top_posts` (`%{title, status, published_at, views}`, most read first), `:referrers`
  (`%{label, count}`, busiest first) and `:audience` (`%{members, guests}`).

  `:from` and `:to` are the window's own bounds, so the page can say which days it is describing
  rather than assuming they match the `days` it asked for.
  """
  @spec load(map() | nil, pos_integer()) :: map()
  def load(user, days \\ @default_days) when days > 0 do
    scope = {Widget.scope(user), MishkaBlog.Dashboard.Overview.areas(user)}
    today = Date.utc_today()
    from = Date.add(today, -(days - 1))
    previous_from = Date.add(from, -days)
    previous_to = Date.add(from, -1)

    views = views_base(scope)
    comments = comments_base(scope)

    rows = window_rows(views, from, today)
    daily = series(rows, from, days)
    views_window = length(rows)
    views_previous = count(in_days(views, previous_from, previous_to))
    comments_window = count(in_days(comments, from, today))

    %{
      days: days,
      from: from,
      to: today,
      views_total: count(views),
      views_window: views_window,
      views_previous: views_previous,
      views_today: count(on_day(views, today)),
      views_yesterday: count(on_day(views, Date.add(today, -1))),
      visitors: visitors(rows),
      comments_window: comments_window,
      engagement_rate: rate(comments_window, views_window),
      engagement_previous:
        rate(count(in_days(comments, previous_from, previous_to)), views_previous),
      series: daily,
      peak: Enum.max_by(daily, & &1.count),
      referrers: referrers(rows),
      audience: audience(rows),
      top_posts: top_posts(rows, scope)
    }
  end

  defp window_rows(views, from, to) do
    views
    |> in_days(from, to)
    |> Ash.Query.select([:inserted_at, :ip_address, :referer, :user_id, :post_id])
    |> Ash.read!(authorize?: false)
  end

  # Every day of the window is emitted, including the empty ones: a line drawn only through the days
  # that happened to have a view would space a quiet week the same as a busy one.
  defp series(rows, from, days) do
    counts = Enum.frequencies_by(rows, &DateTime.to_date(&1.inserted_at))

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(from, offset)

      %{date: date, count: Map.get(counts, date, 0)}
    end)
  end

  # A reader is their account where they have one and their IP where they do not — the same pair the
  # resource dedupes a view on, so this counts the people the view log can actually tell apart.
  defp visitors(rows) do
    rows
    |> Enum.uniq_by(&(&1.user_id || &1.ip_address))
    |> length()
  end

  defp audience(rows) do
    {members, guests} = Enum.split_with(rows, & &1.user_id)

    %{members: length(members), guests: length(guests)}
  end

  defp referrers(rows) do
    rows
    |> Enum.frequencies_by(&source(&1.referer))
    |> Enum.sort_by(fn {label, count} -> {-count, label} end)
    |> Enum.take(@top_referrers)
    |> Enum.map(fn {label, count} -> %{label: label, count: count} end)
  end

  # A view recorded without a referer is a reader who arrived without one — typed in, bookmarked, or
  # from a client that strips the header. That is what direct traffic is, not a missing measurement.
  defp source(nil), do: gettext_noop("Direct")
  defp source(referer), do: referer |> String.trim() |> parse_source()

  defp parse_source(""), do: gettext_noop("Direct")
  defp parse_source(referer), do: referer |> URI.parse() |> Map.get(:host) |> host_label(referer)

  defp host_label(host, _referer) when is_binary(host) and host != "", do: String.downcase(host)
  defp host_label(_host, referer), do: referer

  defp top_posts(rows, scope) do
    rows
    |> Enum.frequencies_by(& &1.post_id)
    |> Enum.sort_by(fn {_id, count} -> -count end)
    |> Enum.take(@top_posts)
    |> with_titles(scope)
  end

  defp with_titles([], _scope), do: []

  # A post the viewer's scope cannot read simply drops out of the ranking rather than appearing as an
  # untitled row: the counts came from a join the tenant can see, the titles must come from one too.
  defp with_titles(counted, scope) do
    views = Map.new(counted)

    scope
    |> posts_base()
    |> Ash.Query.filter(id in ^Map.keys(views))
    |> Ash.Query.select([:id, :title, :status, :published_at])
    |> Ash.read!(page: [limit: map_size(views)], authorize?: false)
    |> Map.fetch!(:results)
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

  defp posts_base(scope),
    do:
      BlogPost
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> by_site(scope, :post)

  defp comments_base(scope),
    do:
      Comment
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> by_site(scope, :comment)

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

  defp held(query, areas, area) do
    case Map.get(areas, area, false) do
      true -> query
      false -> Ash.Query.filter(query, false)
    end
  end

  defp in_days(query, from, to) do
    Ash.Query.filter(
      query,
      inserted_at >= ^beginning_of_day(from) and inserted_at < ^beginning_of_day(Date.add(to, 1))
    )
  end

  defp on_day(query, date), do: in_days(query, date, date)

  defp beginning_of_day(date), do: DateTime.new!(date, ~T[00:00:00])

  defp rate(_interactions, 0), do: 0
  defp rate(interactions, views), do: round(interactions * 100 / views)

  defp count(query), do: Ash.count!(query, authorize?: false)
end
