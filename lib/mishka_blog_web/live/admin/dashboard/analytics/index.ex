defmodule MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index do
  @moduledoc """
  The blog analytics page: five KPI tiles, a daily views chart, the most-read posts, where their
  readers came from and whether they were signed in — every figure read from the view log by
  `MishkaBlog.Dashboard.Analytics`.

  The page shows only what `MishkaBlog.PostView` records. There is no average read time and no bounce
  rate here because nothing in the schema observes a reader leaving a post, and a tile that cannot be
  measured is worse than a tile that is missing.

  The read runs off the render in a `start_async/3` and is repeated whenever the period changes, so
  every figure and every panel describes the same window. A result is only assigned while its `days`
  is still the selected one, so clicking through the periods quickly cannot land an older read on top
  of a newer one. Until the first one lands each figure is an em dash: `kpi_cards/3` has a `nil`
  clause over the same metadata as the real one, so there is no second skeleton to keep in step.

  The chart is inline SVG built from the series — `line_path/2` and `area_path/2` project the daily
  counts onto a fixed viewBox, and `vector-effect="non-scaling-stroke"` keeps the stroke even once
  the box has been stretched to the card's width.

  Number formatting is `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index`'s — `growth/2`, `percent/2`,
  `move_tone/2`, `delta/2` and `status_tone/1` — so the overview and this page colour and word the
  same figures identically rather than drifting apart; counts, dates and percentages are written in
  the reader's language by `MishkaCmsCore.Localized`.

  The page is a holder's of the blog's `admin:dashboard:blog:post` (`MishkaBlogWeb.SidebarMenu`).
  The Engagement tile divides comments by views, so it is drawn only for a viewer who also holds
  `admin:dashboard:blog:comment`.

  See `MishkaBlog.Dashboard.Analytics` for the queries.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Logger

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, as: Home
  alias MishkaCmsCore.Localized

  @chart_width 720
  @chart_height 180
  @gridlines [0, 45, 90, 135, 180]

  @muted "text-[#8a877f]"
  @waiting "text-[#a8a5a0]"

  @kpis [
    {gettext_noop("Total Views"), "hero-eye", "bg-[#eaf1fb] text-[#3a6cb5]", [:post]},
    {gettext_noop("Views in Period"), "hero-arrow-trending-up", "bg-[#eaf6ee] text-[#1f9d6b]",
     [:post]},
    {gettext_noop("Unique Readers"), "hero-users", "bg-[#f1edfb] text-[#7a5bd0]", [:post]},
    {gettext_noop("Views Today"), "hero-calendar-days", "bg-[#fbf1e5] text-[#c07a2a]", [:post]},
    {gettext_noop("Engagement"), "hero-chat-bubble-left-right", "bg-[#eef1fc] text-[#4f4bcc]",
     [:post, :comment]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Blog Analytics"), days: Analytics.default_days(), stats: nil)
      |> assign(:blog_areas, Overview.areas(socket.assigns[:current_user]))
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_range", %{"days" => days}, socket) do
    {:noreply, select_range(socket, Enum.find(Analytics.ranges(), &(to_string(&1) == days)))}
  end

  @impl true
  def handle_async(:stats, {:ok, %{days: days} = stats}, socket) do
    {:noreply, (days == socket.assigns.days && assign(socket, :stats, stats)) || socket}
  end

  def handle_async(name, {:exit, reason}, socket) do
    Logger.error("blog analytics #{name} failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  @doc """
  The KPI tiles `areas` (`MishkaBlog.Dashboard.Overview.areas/1`) may see, as
  `{label, icon, icon_tone, value, note, note_tone}`.

  The `nil` clause is what the page renders until `MishkaBlog.Dashboard.Analytics.load/2` returns.
  """
  @spec kpi_cards(map() | nil, pos_integer(), Overview.areas()) ::
          [{String.t(), String.t(), String.t(), String.t(), String.t(), String.t()}]
  def kpi_cards(stats, days, areas) do
    for {label, icon, tone, needs} <- @kpis, Home.holds?(areas, needs) do
      {value, note, note_tone} = kpi(label, stats, days)
      {Gettext.gettext(MishkaCmsCore.Gettext, label), icon, tone, value, note, note_tone}
    end
  end

  defp kpi(_label, nil, _days), do: {nil, nil, @waiting}

  defp kpi("Total Views", stats, _days),
    do: {Localized.compact(stats.views_total), all_time_note(stats.views_total), @muted}

  defp kpi("Views in Period", stats, days),
    do:
      {Localized.compact(stats.views_window),
       trend(stats.views_window, stats.views_previous, days),
       Home.move_tone(stats.views_window, stats.views_previous)}

  defp kpi("Unique Readers", stats, _days),
    do: {Localized.compact(stats.visitors), readers_note(stats.visitors), @muted}

  defp kpi("Views Today", stats, _days),
    do:
      {Localized.compact(stats.views_today), Home.delta(stats.views_today, stats.views_yesterday),
       Home.move_tone(stats.views_today, stats.views_yesterday)}

  defp kpi("Engagement", stats, days),
    do:
      {Home.percent(stats.engagement_rate),
       engagement_note(stats.engagement_rate, stats.engagement_previous, days),
       Home.move_tone(stats.engagement_rate, stats.engagement_previous)}

  @doc "The horizontal rules the chart is read against, as y positions in the viewBox."
  @spec gridlines() :: [non_neg_integer()]
  def gridlines, do: @gridlines

  @doc "The viewBox the chart is drawn in — a fixed box the card stretches to its own width."
  @spec view_box() :: String.t()
  def view_box, do: "0 0 #{@chart_width} #{@chart_height}"

  @doc "How wide that box is, so a rule can be drawn right across it."
  @spec chart_width() :: pos_integer()
  def chart_width, do: @chart_width

  @doc "The line through the daily view counts, as an SVG path."
  @spec line_path([map()], non_neg_integer()) :: String.t()
  def line_path(series, peak), do: series |> points(peak) |> polyline()

  @doc "The same line closed down to the baseline, so the area beneath it can be filled."
  @spec area_path([map()], non_neg_integer()) :: String.t()
  def area_path(series, peak), do: series |> points(peak) |> enclose()

  @doc "What the chart says for a screen reader, in one sentence."
  @spec chart_label(map()) :: String.t()
  def chart_label(stats) do
    gettext("Daily views from %{from} to %{to}, %{total} in total, peaking at %{peak}",
      from: day_label(stats.from),
      to: day_label(stats.to),
      total: stats.views_window,
      peak: stats.peak.count
    )
  end

  @doc "Month and day, e.g. `\"Jul 20\"` — the chart's axis ends and the peak marker."
  @spec day_label(Date.t()) :: String.t()
  def day_label(date), do: Localized.date(date, :MMMd)

  @doc "A referrer as the page shows it: the `Direct` bucket in the reader's language, a host as it is."
  @spec referrer_label(String.t()) :: String.t()
  def referrer_label(label), do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  @doc "When a top-performing post went out, or that it has not."
  @spec published_label(map()) :: String.t()
  def published_label(%{published_at: %DateTime{} = at}),
    do: gettext("Published %{date}", date: Localized.date(at, :yMMMd))

  def published_label(_post), do: gettext("Not published")

  @doc """
  A count's share of the period's views, as a whole percentage.

  A source with views but under half a percent reads `<1%` rather than `0%`, which would say it
  brought nobody.
  """
  @spec share(non_neg_integer(), non_neg_integer()) :: String.t()
  def share(0, _total), do: Home.percent(0)
  def share(_count, 0), do: Home.percent(0)
  def share(count, total), do: percentage(round(count * 100 / total))

  @doc "The bar width for a share, floored so a small but real source still draws as a bar."
  @spec share_width(non_neg_integer(), non_neg_integer()) :: String.t()
  def share_width(0, _total), do: "width: 0%"
  def share_width(_count, 0), do: "width: 0%"
  def share_width(count, total), do: "width: #{max(round(count * 100 / total), 2)}%"

  defp select_range(socket, nil), do: socket

  defp select_range(socket, days) do
    socket
    |> assign(days: days, stats: nil)
    |> load_stats()
  end

  defp load_stats(socket) do
    user = socket.assigns.current_user
    days = socket.assigns.days

    (connected?(socket) &&
       MishkaGervaz.Messages.start_async(socket, :stats, fn -> Analytics.load(user, days) end)) ||
      socket
  end

  defp points(series, peak) do
    last = max(length(series) - 1, 1)
    top = max(peak, 1)

    series
    |> Enum.with_index()
    |> Enum.map(fn {%{count: count}, index} ->
      {round(index * @chart_width / last), round(@chart_height - count * @chart_height / top)}
    end)
  end

  defp polyline(points) do
    points
    |> Enum.map_join(" ", fn {x, y} -> "L#{x},#{y}" end)
    |> String.replace_prefix("L", "M")
  end

  defp enclose([{first_x, _first_y} | _rest] = points) do
    {last_x, _last_y} = List.last(points)

    polyline(points) <> " L#{last_x},#{@chart_height} L#{first_x},#{@chart_height} Z"
  end

  defp all_time_note(0), do: gettext("No views recorded yet")
  defp all_time_note(_total), do: gettext("All time")

  defp readers_note(0), do: gettext("No readers in this period")
  defp readers_note(_visitors), do: gettext("By account, by IP for guests")

  defp trend(0, 0, days), do: gettext("Nothing in the last %{days} days", days: days)
  defp trend(_current, 0, _days), do: gettext("First views in this period")

  defp trend(current, previous, days),
    do:
      gettext("%{growth} vs previous %{days} days",
        growth: Home.growth(current, previous),
        days: days
      )

  defp engagement_note(rate, rate, days), do: gettext("Steady vs prev. %{days}d", days: days)

  defp engagement_note(rate, previous, days) when rate > previous,
    do:
      gettext("+%{points} pts vs prev. %{days}d",
        points: Localized.number(rate - previous),
        days: days
      )

  defp engagement_note(rate, previous, days),
    do:
      gettext("−%{points} pts vs prev. %{days}d",
        points: Localized.number(previous - rate),
        days: days
      )

  defp percentage(0), do: "<" <> Home.percent(1)
  defp percentage(value), do: Home.percent(value)
end
