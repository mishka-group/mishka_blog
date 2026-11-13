# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Analytics do
  @moduledoc """
  Every number on the blog analytics page (`/admin/dashboard/blog/analytics`), read from the database.

  The page asks for one panel at a time — `load/4` with a panel of `panels/0` — and each panel is
  one or two `GROUP BY` reads (`MishkaBlog.Dashboard.Scope.grouped/2`), most of them over
  `MishkaBlog.PostViewDaily`: one row per post and day with its views and unique readers. Nothing is
  estimated, which is why there is no read time and no bounce rate: nothing observes a reader leaving.

  A reader is counted once a day for each post they read (`MishkaBlog.Views`), so "Unique Readers" is
  the sum of those, and approximate where the site runs on several nodes, each telling its readers
  apart on its own. Views are written within a minute of being counted.

  ## The period

  `period/1` reads the page's URL params into the window asked for: `days` (7, 30 or 90 whole days
  ending today), the same number of days before it to compare against, a `category`, `tag`,
  `blogger` or `team` id that narrows every figure to that one's posts, and `compare`, which draws
  the window before beside this one. `params/1` writes it back, so a reload or a shared link keeps it.

  ## Who reads what

  Every figure is read as `user` through `MishkaBlog.Dashboard.Scope`, as
  `MishkaBlog.Dashboard.Overview` reads its own: a master (a user whose `site_id` is nil) counts every
  site, a site user only its own. A day's row counts only while its post is not archived.

  Views and posts are read only for a holder of `admin:dashboard:blog:post`, and comments only for a
  holder of `admin:dashboard:blog:comment` (`MishkaBlog.Dashboard.Overview.areas/1`) — the
  permissions those resources' policies ask for. A read of an area the viewer does not hold is
  refused and counted as no data; the comment reads are not even run without the comment area, and
  their figures come back `nil`.

  ## The `blog:analytics:panel` event

  Every panel is handed to the plugins of `"blog:analytics:panel"` before the page draws it, as
  `%{panel: atom, period: period, current_user: user, data: map}`; a plugin answers the same map,
  `data` changed or not — to add a figure of its own, or leave out a post it keeps private.

  The caller runs this off the render — see `MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index`.
  """
  import Ecto.Query, only: [from: 2, subquery: 1]

  require Ash.Query

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Comment
  alias MishkaBlog.Dashboard.Figures
  alias MishkaBlog.Dashboard.Scope
  alias MishkaBlog.PostViewDaily

  @ranges [7, 30, 90]
  @default_days 30
  @filters [:category, :tag, :blogger, :team]
  @panels [
    :overview,
    :categories,
    :tags,
    :bloggers,
    :teams,
    :post_age,
    :posts,
    :commenters,
    :comment_status
  ]
  @statuses [:pending, :approved, :flagged, :spam]
  @choice_page 20
  @top 5
  @top_posts 10
  @quiet_below 3
  @fresh_days 30
  @event "blog:analytics:panel"

  @type period :: %{
          days: pos_integer(),
          from: Date.t(),
          to: Date.t(),
          previous_from: Date.t(),
          previous_to: Date.t(),
          filters: %{optional(atom()) => String.t()},
          compare: boolean()
        }

  @doc "The windows the page offers, in whole days."
  @spec ranges() :: [pos_integer()]
  def ranges, do: @ranges

  @doc "The window the page opens on, in whole days."
  @spec default_days() :: pos_integer()
  def default_days, do: @default_days

  @doc "What a period can be narrowed by: a category, a tag, a blogger or a team."
  @spec filters() :: [atom()]
  def filters, do: @filters

  @doc "The statuses a comment is counted under, in the order the page shows them."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The panels `load/4` reads, each on its own."
  @spec panels() :: [atom()]
  def panels, do: @panels

  @doc "The event a panel is handed to before the page draws it."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The period the URL params `params` ask for, ending today. A `days` the page does not offer is the
  default, and a filter that is not an id is left out.
  """
  @spec period(map()) :: period()
  def period(params) do
    days = Enum.find(@ranges, @default_days, &(to_string(&1) == params["days"]))
    to = Date.utc_today()
    from = Date.add(to, -(days - 1))

    %{
      days: days,
      from: from,
      to: to,
      previous_from: Date.add(from, -days),
      previous_to: Date.add(from, -1),
      filters: for(key <- @filters, id <- uuid(params[to_string(key)]), into: %{}, do: {key, id}),
      compare: params["compare"] == "true"
    }
  end

  @doc "The URL params of `period`, leaving out what is the default."
  @spec params(period()) :: map()
  def params(period) do
    period.filters
    |> Map.new(fn {key, id} -> {to_string(key), id} end)
    |> put_param("days", period.days != @default_days && to_string(period.days))
    |> put_param("compare", period.compare && "true")
  end

  defp put_param(params, _key, false), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> [id]
      :error -> []
    end
  end

  defp uuid(_value), do: []

  @doc """
  One page of what the `kind` filter (`:category`, `:tag`, `:blogger` or `:team`) can be set to, as
  `user` reads them, by name: `{[{label, id}], more?}`, as gervaz's search select takes its options. An archived one is left out. Names that
  repeat — a category in several languages or on several sites — are told apart by their language
  and site: `"Travel · en · site-a"`.

  `opts` are `:search`, a part of the name to look for, and `:offset`, where the page starts; or
  `:id` alone, to label one already picked (`{[{label, id}], false}`, or `{[], false}` when the
  viewer cannot read it).
  """
  @spec choices(atom(), map(), keyword()) :: {[{String.t(), String.t()}], boolean()}
  def choices(kind, user, opts) when kind in @filters do
    {resource, field} = term_of(kind)
    language? = Ash.Resource.Info.attribute(resource, :language) != nil

    rows =
      resource
      |> Scope.query(user)
      |> Scope.grouped(fn query ->
        from(r in query,
          join: s in MishkaCmsCore.Runtime.Site,
          on: s.id == r.site_id,
          where: is_nil(r.archived_at),
          windows: [same_name: [partition_by: field(r, ^field)]],
          order_by: [field(r, ^field), r.id],
          select: %{
            id: r.id,
            name: field(r, ^field),
            site: s.name,
            repeats: over(count(r.id), :same_name)
          }
        )
        |> with_language(language?)
        |> choose(resource, field, opts)
      end)

    picked(rows, opts[:id])
  end

  defp picked(rows, nil) do
    {page, rest} = Enum.split(rows, @choice_page)

    {Enum.map(page, &{choice_label(&1), &1.id}), rest != []}
  end

  defp picked(rows, id),
    do: {for(%{id: ^id} = row <- rows, do: {choice_label(row), id}), false}

  defp term_of(:category), do: {MishkaBlog.Collection, :name}
  defp term_of(:tag), do: {MishkaBlog.Tag, :name}
  defp term_of(:blogger), do: {MishkaBlog.Blogger, :display_name}
  defp term_of(:team), do: {MishkaBlog.Team, :name}

  # The one picked is looked for among those of its name, so its label is told apart as in the list.
  defp choose(query, resource, field, opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} ->
        named = from(x in resource, where: x.id == ^id, select: field(x, ^field))
        from([r] in query, where: field(r, ^field) in subquery(named))

      :error ->
        query
        |> search(field, opts[:search])
        |> from(limit: ^(@choice_page + 1), offset: ^Keyword.get(opts, :offset, 0))
    end
  end

  defp search(query, _field, term) when term in [nil, ""], do: query

  defp search(query, field, term) do
    pattern = "%" <> String.replace(term, ~w(\\ % _), &("\\" <> &1)) <> "%"

    from([r] in query, where: ilike(field(r, ^field), ^pattern))
  end

  defp choice_label(%{repeats: 1, name: name}), do: name

  defp choice_label(row) do
    [row.name, Map.get(row, :language), row.site]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp with_language(query, true), do: from([r] in query, select_merge: %{language: r.language})
  defp with_language(query, false), do: query

  @doc """
  Reads `panel` for `period` as `user`, then hands it to the `blog:analytics:panel` plugins.
  `comments?` says whether the viewer holds the comment area; without it no comment is read.

    * `:overview` — the KPI figures, the daily views of the window and of the one before
      (`:series`, `:previous_series`), views per weekday (`:weekdays`), views and posts published
      per week (`:weeks`) and the daily comments (`:comments`, `nil` without the comment area);
    * `:categories` — the views of the five categories read most, day by day for a stacked chart
      (`:series`, every other category's under `:other`), and their totals and share (`:top`);
    * `:tags`, `:bloggers` and `:teams` — the five read most, with their views and share; a blogger
      also with the posts it published in the window and the comments its posts were given; a
      team counts a post its members co-wrote once;
    * `:post_age` — the views of posts published in the last thirty days and of older ones;
    * `:posts` — the posts read most (`:top`), those that grew most against the window before
      (`:rising`), and published posts almost nobody read (`:quiet`);
    * `:commenters` — who wrote the most comments in the window (`[]` without the comment area);
    * `:comment_status` — the window's comments by status (`statuses/0`), `nil` without the comment
      area.
  """
  @spec load(atom(), map(), period(), boolean()) :: map() | list()
  def load(panel, user, period, comments?) when panel in @panels do
    data = read(panel, user, period, comments?)

    case MishkaInstaller.Event.Hook.call(@event, %{
           panel: panel,
           period: period,
           current_user: user,
           data: data
         }) do
      %{data: data} -> data
      _other -> data
    end
  end

  defp read(:overview, user, period, comments?) do
    by_day =
      user
      |> views(period, period.previous_from)
      |> grouped(
        :post_id,
        period,
        &from(r in &1,
          group_by: r.day,
          select: {r.day, {type(sum(r.views), :integer), type(sum(r.unique_readers), :integer)}}
        )
      )
      |> Map.new()

    series = daily(by_day, period.from, period.to, &elem(&1, 0))
    previous_series = daily(by_day, period.previous_from, period.previous_to, &elem(&1, 0))
    views_window = Enum.sum_by(series, & &1.count)
    views_previous = Enum.sum_by(previous_series, & &1.count)
    comments = comments?(comments?, fn -> comments_by_day(user, period) end)

    %{
      views_total: views_total(user, period),
      views_window: views_window,
      views_previous: views_previous,
      views_today: by_day |> Map.get(period.to, {0, 0}) |> elem(0),
      views_yesterday: by_day |> Map.get(Date.add(period.to, -1), {0, 0}) |> elem(0),
      visitors: by_day |> daily(period.from, period.to, &elem(&1, 1)) |> Enum.sum_by(& &1.count),
      series: series,
      previous_series: previous_series,
      peak: Enum.max_by(series, & &1.count),
      weekdays: weekdays(series),
      weeks: weeks(series, published_by_week(user, period)),
      comments: comments,
      comments_window: comments && comments.window,
      engagement_rate: comments && Figures.rate(comments.window, views_window),
      engagement_previous: comments && Figures.rate(comments.previous, views_previous)
    }
  end

  defp read(:categories, user, period, _comments?) do
    rows =
      user
      |> views(period, period.from)
      |> grouped(
        :post_id,
        period,
        &from([r] in &1,
          left_join: pc in MishkaBlog.PostCollection,
          on: pc.post_id == r.post_id,
          left_join: c in MishkaBlog.Collection,
          on: c.id == pc.collection_id,
          group_by: [r.day, c.id],
          select:
            {r.day, %{id: c.id, name: c.name, archived?: not is_nil(c.archived_at)},
             type(sum(r.views), :integer)}
        )
      )

    top =
      rows
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Enum.map(fn {term, views} -> {term, Enum.sum(views)} end)
      |> ranked()

    shown = MapSet.new(top, & &1.id)

    series =
      Enum.map(days(period.from, period.to), fn date ->
        counts =
          for {^date, %{id: id}, views} <- rows, reduce: %{} do
            acc ->
              Map.update(acc, (MapSet.member?(shown, id) && id) || :other, views, &(&1 + views))
          end

        %{date: date, counts: counts}
      end)

    %{top: top, series: series}
  end

  defp read(:tags, user, period, _comments?) do
    user
    |> views(period, period.from)
    |> grouped(
      :post_id,
      period,
      &from([r] in &1,
        join: pt in MishkaBlog.PostTag,
        on: pt.post_id == r.post_id,
        join: t in MishkaBlog.Tag,
        on: t.id == pt.tag_id,
        group_by: t.id,
        select:
          {%{id: t.id, name: t.name, archived?: not is_nil(t.archived_at)},
           type(sum(r.views), :integer)}
      )
    )
    |> ranked()
  end

  defp read(:bloggers, user, period, comments?) do
    top =
      user
      |> views(period, period.from)
      |> grouped(
        :post_id,
        period,
        &from([r] in &1,
          join: pb in MishkaBlog.PostBlogger,
          on: pb.post_id == r.post_id,
          join: b in MishkaBlog.Blogger,
          on: b.id == pb.blogger_id,
          group_by: b.id,
          select:
            {%{id: b.id, name: b.display_name, archived?: not is_nil(b.archived_at)},
             type(sum(r.views), :integer)}
        )
      )
      |> ranked()

    ids = Enum.map(top, & &1.id)
    published = user |> published(period) |> by_blogger(:id, period, ids)

    comments =
      comments?(comments?, fn ->
        user |> comments(period, period.from) |> by_blogger(:post_id, period, ids)
      end)

    Enum.map(
      top,
      &Map.merge(&1, %{
        posts: Map.get(published, &1.id, 0),
        comments: comments && Map.get(comments, &1.id, 0)
      })
    )
  end

  defp read(:post_age, user, period, _comments?) do
    cutoff = Figures.beginning_of_day(Date.add(period.to, -(@fresh_days - 1)))

    rows =
      user
      |> views(period, period.from)
      |> grouped(
        :post_id,
        period,
        &from([r, post: p] in &1,
          group_by: selected_as(:fresh),
          select: %{
            fresh:
              selected_as(fragment("coalesce(? >= ?, false)", p.published_at, ^cutoff), :fresh),
            views: type(sum(r.views), :integer)
          }
        )
      )
      |> Map.new(&{&1.fresh, &1.views})

    %{fresh: Map.get(rows, true, 0), older: Map.get(rows, false, 0), fresh_days: @fresh_days}
  end

  defp read(:posts, user, period, comments?) do
    from = period.from

    rows =
      user
      |> views(period, period.previous_from)
      |> grouped(
        :post_id,
        period,
        &from([r, post: p] in &1,
          group_by: [p.id, p.title, p.status, p.published_at],
          select: %{
            id: p.id,
            title: p.title,
            status: p.status,
            published_at: p.published_at,
            views: type(coalesce(filter(sum(r.views), r.day >= ^from), 0), :integer),
            readers: type(coalesce(filter(sum(r.unique_readers), r.day >= ^from), 0), :integer),
            previous: type(coalesce(filter(sum(r.views), r.day < ^from), 0), :integer)
          }
        )
      )

    top =
      rows
      |> Enum.filter(&(&1.views > 0))
      |> Enum.sort_by(&{-&1.views, &1.title})
      |> Enum.take(@top_posts)

    comments = comments?(comments?, fn -> comments_by_post(user, period, top) end)

    %{
      top: Enum.map(top, &with_comments(&1, comments)),
      rising:
        rows
        |> Enum.filter(&(&1.views > &1.previous))
        |> Enum.sort_by(&{&1.previous - &1.views, &1.title})
        |> Enum.take(@top)
        |> Enum.map(&Map.put(&1, :change, change(&1.views, &1.previous))),
      quiet: quiet(user, period)
    }
  end

  # A post two members of one team wrote counts once for that team: each day's row is taken once per
  # team before it is summed.
  defp read(:teams, user, period, _comments?) do
    user
    |> views(period, period.from)
    |> grouped(:post_id, period, fn query ->
      rows =
        from([r] in query,
          join: pb in MishkaBlog.PostBlogger,
          on: pb.post_id == r.post_id,
          join: tm in MishkaBlog.TeamMember,
          on: tm.blogger_id == pb.blogger_id,
          distinct: true,
          select: %{team_id: tm.team_id, row: r.id, views: r.views}
        )

      from(x in subquery(rows),
        join: t in MishkaBlog.Team,
        on: t.id == x.team_id,
        group_by: t.id,
        select:
          {%{id: t.id, name: t.name, archived?: not is_nil(t.archived_at)},
           type(sum(x.views), :integer)}
      )
    end)
    |> ranked()
  end

  defp read(:comment_status, _user, _period, false), do: nil

  defp read(:comment_status, user, period, true) do
    counted =
      user
      |> comments(period, period.from)
      |> grouped(
        :post_id,
        period,
        &from(c in &1, group_by: c.status, select: {c.status, type(count(), :integer)})
      )
      |> Map.new()

    Map.new(@statuses, &{&1, Map.get(counted, &1, 0)})
  end

  defp read(:commenters, _user, _period, false), do: []

  defp read(:commenters, user, period, true) do
    counted =
      user
      |> comments(period, period.from)
      |> grouped(
        :post_id,
        period,
        &from(c in &1,
          group_by: [c.author_id, c.guest_name],
          order_by: [desc: count()],
          limit: @top,
          select: {c.author_id, c.guest_name, type(count(), :integer)}
        )
      )

    authors = authors(user, for({id, _guest, _count} when is_binary(id) <- counted, do: id))

    Enum.map(counted, fn {id, guest, count} ->
      %{comment: Map.get(authors, id, %{author_id: id, guest_name: guest}), count: count}
    end)
  end

  @doc """
  `posts` ordered by `key` — `:views`, `:readers`, `:comments`, `:engagement` or `:change` — the
  largest first; any other key orders by views.
  """
  @spec sort_posts([map()], atom()) :: [map()]
  def sort_posts(posts, key) when key in [:readers, :comments, :engagement, :change],
    do: Enum.sort_by(posts, &{-(Map.get(&1, key) || 0), -&1.views})

  def sort_posts(posts, _key), do: Enum.sort_by(posts, &{-&1.views, &1.title})

  defp with_comments(post, comments) do
    count = comments && Map.get(comments, post.id, 0)

    Map.merge(post, %{
      comments: count,
      engagement: count && Figures.rate(count, post.views),
      change: change(post.views, post.previous)
    })
  end

  # The share of growth against the window before, as whole percent; `nil` when there was nothing
  # to grow from.
  defp change(_views, 0), do: nil
  defp change(views, previous), do: round((views - previous) * 100 / previous)

  # The five most read of `counted` (`{%{id, name, archived?}, views}`), with their share of every
  # view counted. The name is joined in the same read, so an archived one is still named.
  defp ranked(counted) do
    total = Enum.sum_by(counted, &elem(&1, 1))

    counted
    |> Enum.reject(fn {term, _views} -> is_nil(term.id) end)
    |> Enum.sort_by(fn {term, views} -> {-views, term.name} end)
    |> Enum.take(@top)
    |> Enum.map(fn {term, views} ->
      Map.merge(term, %{views: views, share: Figures.rate(views, total)})
    end)
  end

  defp authors(_user, []), do: %{}

  defp authors(user, ids) do
    Comment
    |> Scope.query(user)
    |> Ash.Query.filter(author_id in ^ids)
    |> Ash.Query.distinct([:author_id])
    |> Ash.Query.load([:author, :author_profile, :author_master?])
    |> Scope.list(length(ids))
    |> Map.new(&{&1.author_id, &1})
  end

  # A `GROUP BY` over `query`, narrowed by the period's filters on the post id held in `column`; a
  # daily row's post is joined as `:post`, and counts only while that post is not archived.
  defp grouped(%{resource: PostViewDaily} = query, column, period, build) do
    Scope.grouped(query, fn ecto ->
      from(r in ecto,
        join: p in BlogPost,
        as: :post,
        on: p.id == r.post_id and is_nil(p.archived_at)
      )
      |> narrow(column, period.filters)
      |> build.()
    end)
  end

  defp grouped(query, column, period, build),
    do: Scope.grouped(query, &(&1 |> narrow(column, period.filters) |> build.()))

  defp narrow(query, column, filters) do
    Enum.reduce(filters, query, fn {key, id}, query ->
      from([x] in query, where: field(x, ^column) in subquery(posts_of(key, id)))
    end)
  end

  defp posts_of(:category, id),
    do: from(pc in MishkaBlog.PostCollection, where: pc.collection_id == ^id, select: pc.post_id)

  defp posts_of(:tag, id),
    do: from(pt in MishkaBlog.PostTag, where: pt.tag_id == ^id, select: pt.post_id)

  defp posts_of(:blogger, id),
    do: from(pb in MishkaBlog.PostBlogger, where: pb.blogger_id == ^id, select: pb.post_id)

  defp posts_of(:team, id) do
    from(pb in MishkaBlog.PostBlogger,
      join: tm in MishkaBlog.TeamMember,
      on: tm.blogger_id == pb.blogger_id,
      where: tm.team_id == ^id,
      select: pb.post_id
    )
  end

  defp views(user, period, from) do
    to = period.to

    PostViewDaily
    |> Scope.query(user)
    |> Ash.Query.filter(day >= ^from and day <= ^to)
  end

  defp views_total(user, period) do
    PostViewDaily
    |> Scope.query(user)
    |> grouped(
      :post_id,
      period,
      &from([r] in &1, select: type(coalesce(sum(r.views), 0), :integer))
    )
    |> List.first(0)
  end

  defp published(user, period) do
    from = Figures.beginning_of_day(period.from)
    to = Figures.beginning_of_day(Date.add(period.to, 1))

    BlogPost
    |> Scope.query(user, :read_any)
    |> Ash.Query.filter(status == :published and published_at >= ^from and published_at < ^to)
  end

  defp published_by_week(user, period) do
    user
    |> published(period)
    |> grouped(
      :id,
      period,
      &from([p] in &1,
        group_by: fragment("date_trunc('week', ?)::date", p.published_at),
        select:
          {type(fragment("date_trunc('week', ?)::date", p.published_at), :date),
           type(count(), :integer)}
      )
    )
    |> Map.new()
  end

  defp quiet(user, period) do
    from = period.from
    to = period.to
    published_before = Figures.beginning_of_day(Date.add(to, 1))

    BlogPost
    |> Scope.query(user, :read_any)
    |> Ash.Query.filter(status == :published and published_at < ^published_before)
    |> grouped(
      :id,
      period,
      &from([p] in &1,
        left_join: r in PostViewDaily,
        on: r.post_id == p.id and r.day >= ^from and r.day <= ^to,
        group_by: [p.id, p.title, p.status, p.published_at],
        having: coalesce(sum(r.views), 0) < @quiet_below,
        order_by: [asc: coalesce(sum(r.views), 0), desc: p.published_at],
        limit: @top,
        select: %{
          id: p.id,
          title: p.title,
          status: p.status,
          published_at: p.published_at,
          views: type(coalesce(sum(r.views), 0), :integer)
        }
      )
    )
  end

  defp comments(user, period, from) do
    from = Figures.beginning_of_day(from)
    to = Figures.beginning_of_day(Date.add(period.to, 1))

    Comment
    |> Scope.query(user)
    |> Ash.Query.filter(inserted_at >= ^from and inserted_at < ^to)
  end

  defp comments_by_day(user, period) do
    by_day =
      user
      |> comments(period, period.previous_from)
      |> grouped(
        :post_id,
        period,
        &from(c in &1,
          group_by: fragment("?::date", c.inserted_at),
          select: {type(fragment("?::date", c.inserted_at), :date), type(count(), :integer)}
        )
      )
      |> Map.new()

    series = daily(by_day, period.from, period.to, & &1)
    previous = daily(by_day, period.previous_from, period.previous_to, & &1)

    %{
      series: series,
      previous_series: previous,
      window: Enum.sum_by(series, & &1.count),
      previous: Enum.sum_by(previous, & &1.count)
    }
  end

  defp comments_by_post(_user, _period, []), do: %{}

  defp comments_by_post(user, period, posts) do
    ids = Enum.map(posts, & &1.id)

    user
    |> comments(period, period.from)
    |> Ash.Query.filter(post_id in ^ids)
    |> grouped(
      :post_id,
      period,
      &from(c in &1, group_by: c.post_id, select: {c.post_id, type(count(), :integer)})
    )
    |> Map.new()
  end

  defp by_blogger(_query, _column, _period, []), do: %{}

  defp by_blogger(query, column, period, ids) do
    query
    |> grouped(
      column,
      period,
      &from([x] in &1,
        join: pb in MishkaBlog.PostBlogger,
        on: pb.post_id == field(x, ^column),
        where: pb.blogger_id in ^ids,
        group_by: pb.blogger_id,
        select: {pb.blogger_id, type(count(), :integer)}
      )
    )
    |> Map.new()
  end

  defp comments?(true, read), do: read.()
  defp comments?(false, _read), do: nil

  defp daily(by_day, from, to, pick) do
    Enum.map(days(from, to), fn date ->
      %{date: date, count: (Map.has_key?(by_day, date) && pick.(by_day[date])) || 0}
    end)
  end

  defp days(from, to), do: Enum.to_list(Date.range(from, to))

  # Monday first, as `Date.day_of_week/1` counts.
  defp weekdays(series) do
    sums = Enum.group_by(series, &Date.day_of_week(&1.date), & &1.count)

    Enum.map(1..7, &%{day: &1, count: sums |> Map.get(&1, []) |> Enum.sum()})
  end

  defp weeks(series, published) do
    series
    |> Enum.group_by(&Date.beginning_of_week(&1.date), & &1.count)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {week, counts} ->
      %{week: week, views: Enum.sum(counts), posts: Map.get(published, week, 0)}
    end)
  end
end
