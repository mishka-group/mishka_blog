# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index do
  @moduledoc """
  The blog analytics page: KPI tiles, charts of views, categories, tags, bloggers, publishing, post
  age, weekdays and comments, and three post tables — every figure read from the daily view counts
  (`MishkaBlog.PostViewDaily`) and the comments by `MishkaBlog.Dashboard.Analytics`.

  The page shows only what is counted. There is no average read time, no bounce rate and no
  referrer here because nothing observes a reader leaving a post or keeps where they came from, and
  a tile that cannot be measured is worse than a tile that is missing. Unique Readers says it is
  approximate: each node of a site tells its readers apart on its own.

  ## The URL

  The period (7, 30 or 90 days), the Category, Tag, Blogger and Team filters, "Compare with previous
  period" and the Top Posts sort all live in the URL (`handle_params/3`), so a reload or a shared link
  opens the same view. The range buttons and the sort headers are patch links, the filter bar a form
  whose change patches the URL.

  ## Loading

  The page draws first, every panel as a skeleton, then each panel of
  `MishkaBlog.Dashboard.Analytics.panels/0` is read in its own `start_async/3` and drawn when it
  lands. A changed period starts them all again; a result is only assigned while its period is still
  the one shown, so clicking through quickly cannot land an older read on top of a newer one. A new
  sort only reorders the posts already read.

  The charts are inline SVG built from the series — `xy/3` projects counts onto a fixed viewBox and
  `vector-effect="non-scaling-stroke"` keeps a stroke even once the box is stretched to the card.

  Number formatting is `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index`'s — `growth/2`, `percent/2`,
  `move_tone/2`, `delta/2` and `status_tone/1` — so the overview and this page word the same figures
  identically; counts, dates and percentages are written in the reader's language by
  `MishkaCmsCore.Localized`.

  The page is a holder's of the blog's `admin:dashboard:blog:post` (`MishkaBlogWeb.SidebarMenu`).
  Every comment figure — the Engagement tile, the comments chart and top commenters, a blogger's
  comments and a post's comments and engagement — is drawn only for a viewer who also holds
  `admin:dashboard:blog:comment`, and is not read for any other.
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
  @sorts [:views, :readers, :comments, :engagement, :change]
  @layers ["#5b57d6", "#1f9d6b", "#c07a2a", "#3a6cb5", "#c2457a", "#c3c0b8"]

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
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(page_title: gettext("Blog Analytics"), period: nil, sort: :views, options: nil)
      |> assign(blog_areas: Overview.areas(user), panels: empty_panels())

    socket =
      (connected?(socket) &&
         MishkaGervaz.Messages.start_async(socket, :options, fn -> Analytics.options(user) end)) ||
        socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = Analytics.period(params)
    sort = Enum.find(@sorts, :views, &(to_string(&1) == params["sort"]))
    socket = assign(socket, :sort, sort)

    {:noreply, (period == socket.assigns.period && socket) || load_panels(socket, period)}
  end

  @impl true
  def handle_event("filter", %{"filters" => form}, socket) do
    period = socket.assigns.period

    filters =
      for key <- Analytics.filters(), form[to_string(key)] not in [nil, ""], into: %{} do
        {key, form[to_string(key)]}
      end

    period = %{period | filters: filters, compare: form["compare"] == "true"}

    {:noreply, push_patch(socket, to: page_path(socket, period, socket.assigns.sort))}
  end

  @impl true
  def handle_async(:options, {:ok, options}, socket),
    do: {:noreply, assign(socket, :options, options)}

  def handle_async({:panel, panel}, {:ok, {period, data}}, socket) do
    socket =
      (period == socket.assigns.period &&
         assign(socket, :panels, Map.put(socket.assigns.panels, panel, data))) || socket

    {:noreply, socket}
  end

  def handle_async(name, {:exit, reason}, socket) do
    Logger.error("blog analytics #{inspect(name)} failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  @doc """
  This page's address for `period`, with the posts sorted by `sort` — what the range buttons, the
  filter bar and the sort headers patch to.
  """
  @spec page_path(Phoenix.LiveView.Socket.t(), Analytics.period(), atom()) :: String.t()
  def page_path(socket, period, sort) do
    params = Analytics.params(period)
    params = (sort == :views && params) || Map.put(params, "sort", to_string(sort))
    query = (params == %{} && "") || "?" <> URI.encode_query(params)

    path(socket, "/admin/dashboard/blog/analytics#{query}")
  end

  @doc "The sorts the Top Posts table offers, as `{key, label}`; Comments and Engagement need the comment area."
  @spec sorts(Overview.areas()) :: [{atom(), String.t()}]
  def sorts(areas) do
    for {key, label, needs} <- [
          {:views, gettext("Views"), [:post]},
          {:readers, gettext("Readers"), [:post]},
          {:comments, gettext("Comments"), [:post, :comment]},
          {:engagement, gettext("Engagement"), [:post, :comment]},
          {:change, gettext("Change"), [:post]}
        ],
        Home.holds?(areas, needs),
        do: {key, label}
  end

  @doc "The filter bar's selects, as `{key, label, options}`, options `nil` until they are read."
  @spec filter_fields(map() | nil) :: [{atom(), String.t(), [{String.t(), String.t()}] | nil}]
  def filter_fields(options) do
    for {key, label} <- [
          category: gettext("Category"),
          tag: gettext("Tag"),
          blogger: gettext("Blogger"),
          team: gettext("Team")
        ],
        do: {key, label, options && Map.fetch!(options, key)}
  end

  @doc """
  The KPI tiles `areas` (`MishkaBlog.Dashboard.Overview.areas/1`) may see, as
  `{label, icon, icon_tone, value, note, note_tone}`.

  The `nil` clause is what the page renders until the overview panel lands.
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
      {Home.percent(stats.engagement_rate || 0),
       engagement_note(stats.engagement_rate || 0, stats.engagement_previous || 0, days),
       Home.move_tone(stats.engagement_rate || 0, stats.engagement_previous || 0)}

  @doc "The horizontal rules the charts are read against, as y positions in the viewBox."
  @spec gridlines() :: [non_neg_integer()]
  def gridlines, do: @gridlines

  @doc "The viewBox the charts are drawn in — a fixed box the card stretches to its own width."
  @spec view_box() :: String.t()
  def view_box, do: "0 0 #{@chart_width} #{@chart_height}"

  @doc "How wide that box is, so a rule can be drawn right across it."
  @spec chart_width() :: pos_integer()
  def chart_width, do: @chart_width

  @doc "The line through `series`' counts (`%{count: n}` each), against `peak`, as an SVG path."
  @spec line_path([map()], non_neg_integer()) :: String.t()
  def line_path(series, peak), do: series |> Enum.map(& &1.count) |> xy(peak) |> polyline()

  @doc "The same line closed down to the baseline, so the area beneath it can be filled."
  @spec area_path([map()], non_neg_integer()) :: String.t()
  def area_path(series, peak),
    do: band(Enum.map(series, & &1.count), Enum.map(series, fn _day -> 0 end), peak)

  @doc """
  The stacked areas of the categories chart, bottom first, as `{key, colour, path}`: `keys` are the
  categories shown then `:other`, and each day's `counts` is keyed the same.
  """
  @spec stack_paths([map()], [term()]) :: [{term(), String.t(), String.t()}]
  def stack_paths(series, keys) do
    totals = Enum.map(series, fn day -> day.counts |> Map.values() |> Enum.sum() end)
    peak = Enum.max([1 | totals])

    keys
    |> Enum.with_index()
    |> Enum.map_reduce(Enum.map(series, fn _day -> 0 end), fn {key, index}, lower ->
      upper = Enum.zip_with(lower, series, &(&1 + Map.get(&2.counts, key, 0)))
      {{key, layer_colour(index), band(upper, lower, peak)}, upper}
    end)
    |> elem(0)
  end

  @doc "The colour of the `index`th stacked layer; the last, Other, is grey."
  @spec layer_colour(non_neg_integer()) :: String.t()
  def layer_colour(index), do: Enum.at(@layers, index, List.last(@layers))

  @doc "The keys of the categories chart, bottom first: the categories shown, then `:other`."
  @spec stack_keys(map()) :: [term()]
  def stack_keys(%{top: top}), do: Enum.map(top, & &1.id) ++ [:other]

  @doc "The publishing chart's weekly views line, against the busiest week."
  @spec weeks_line([map()]) :: String.t()
  def weeks_line(weeks) do
    weeks
    |> Enum.map(& &1.views)
    |> xy(weeks |> Enum.map(& &1.views) |> Enum.max(fn -> 0 end))
    |> polyline()
  end

  @doc "How tall a bar of `count` is against `peak`, as a percent of its track (never 0 for a count)."
  @spec bar_height(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def bar_height(0, _peak), do: 0
  def bar_height(count, peak), do: max(round(count * 100 / max(peak, 1)), 3)

  @doc """
  The top of a time chart's scale: the busiest day of `series`, or of `previous` too when the window
  before is drawn beside it.
  """
  @spec chart_peak([map()], [map()], boolean()) :: non_neg_integer()
  def chart_peak(series, _previous, false), do: peak_of(series, :count)

  def chart_peak(series, previous, true),
    do: max(peak_of(series, :count), peak_of(previous, :count))

  @doc "Every view the Post Age panel splits."
  @spec post_age_total(map()) :: non_neg_integer()
  def post_age_total(%{fresh: fresh, older: older}), do: fresh + older

  @doc "The largest `key` in `rows`, or `0`."
  @spec peak_of([map()], atom()) :: non_neg_integer()
  def peak_of(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max(fn -> 0 end)

  @doc "What the views chart says for a screen reader, in one sentence."
  @spec chart_label(map()) :: String.t()
  def chart_label(stats) do
    gettext("Daily views from %{from} to %{to}, %{total} in total, peaking at %{peak}",
      from: day_label(List.first(stats.series).date),
      to: day_label(List.last(stats.series).date),
      total: stats.views_window,
      peak: stats.peak.count
    )
  end

  @doc "Month and day, e.g. `\"Jul 20\"` — the charts' axis ends and the peak marker."
  @spec day_label(Date.t()) :: String.t()
  def day_label(date), do: Localized.date(date, :MMMd)

  @doc "A weekday's short name, `1` Monday to `7` Sunday, in the reader's language."
  @spec weekday_label(1..7) :: String.t()
  def weekday_label(day), do: Localized.date(Date.add(~D[2024-01-01], day - 1), :E)

  @doc "When a post went out, or that it has not."
  @spec published_label(map()) :: String.t()
  def published_label(%{published_at: %DateTime{} = at}),
    do: gettext("Published %{date}", date: Localized.date(at, :yMMMd))

  def published_label(_post), do: gettext("Not published")

  @doc "A post's change against the window before, worded: `+40%`, `−10%`, or New."
  @spec change_label(integer() | nil) :: String.t()
  def change_label(nil), do: gettext("New")
  def change_label(points), do: Home.percent(points, sign_display: :except_zero)

  @doc "Tone for a change: green up, red down, muted level or new."
  @spec change_tone(integer() | nil) :: String.t()
  def change_tone(nil), do: @muted
  def change_tone(points), do: Home.move_tone(points, 0)

  @doc "A commenter's name as the comments page writes it."
  @spec commenter(map()) :: String.t()
  def commenter(comment), do: MishkaBlogWeb.Templates.CommentCard.author(comment)

  @doc "A ranked row's name, marked when it is archived; a word for one with no name."
  @spec name_of(map()) :: String.t()
  def name_of(%{name: name, archived?: true}) when is_binary(name),
    do: gettext("%{name} (archived)", name: name)

  def name_of(%{name: name}) when is_binary(name), do: name
  def name_of(_row), do: gettext("Unnamed")

  @doc "The name of a stacked layer's key: a category's, or Other."
  @spec layer_name(map(), term()) :: String.t()
  def layer_name(_categories, :other), do: gettext("Other")

  def layer_name(%{top: top}, id),
    do: top |> Enum.find(%{}, &(&1.id == id)) |> name_of()

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, default: nil
  attr :icon, :string, default: "hero-chart-bar"
  attr :loading, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc "A panel of the page: a titled card whose body is a skeleton until its data lands."
  def panel(assigns) do
    ~H"""
    <section
      data-role={@id}
      class={[
        "min-w-0 rounded-[18px] border border-[#ecebe6] bg-white px-[22px] py-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] max-[560px]:px-4!",
        @class
      ]}
    >
      <div class="mb-4 flex items-center gap-[11px]">
        <span class="grid size-8 flex-none place-items-center rounded-[9px] bg-[#f2f1fc] text-[#5b57d6]">
          <.icon name={@icon} class="size-4" />
        </span>
        <div class="min-w-0">
          <h2 class="font-['Space_Grotesk'] text-[16px] font-bold text-[#17161a]">{@title}</h2>
          <div :if={@note} class="mt-px text-[12px] font-medium text-[#8a877f]">{@note}</div>
        </div>
      </div>
      <div :if={@loading} class="flex animate-pulse flex-col gap-2.5">
        <div :for={w <- [86, 64, 72, 48]} class="h-3 rounded bg-[#f2f1ee]" style={"width: #{w}%"}>
        </div>
      </div>
      <div :if={!@loading}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :icon, :string, default: "hero-eye-slash"
  attr :text, :string, required: true

  @doc "What a panel says when its period holds nothing."
  def empty(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-2.5 rounded-[14px] border border-dashed border-[#e6e4de] py-9 text-center">
      <span class="grid size-10 place-items-center rounded-[11px] bg-[#f2f1ec] text-[#a8a5a0]">
        <.icon name={@icon} class="size-[18px]" />
      </span>
      <div class="text-[12px] font-medium text-[#8a877f]">{@text}</div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :empty, :string, required: true

  @doc "A ranked bar list: each row's name, views and share of the whole as a bar."
  def bar_list(assigns) do
    ~H"""
    <.empty :if={@rows == []} text={@empty} />
    <ol :if={@rows != []} class="flex flex-col gap-3">
      <li :for={row <- @rows}>
        <div class="flex items-baseline justify-between gap-3 text-[12.5px]">
          <span class="min-w-0 truncate font-semibold text-[#1b1a18]">{name_of(row)}</span>
          <span class="flex-none font-semibold text-[#6d6a63]">
            {Localized.compact(row.views)}
            <span class="ms-1 text-[11px] text-[#a8a5a0]">{Home.percent(row.share)}</span>
          </span>
        </div>
        <div class="mt-1.5 h-2 rounded-full bg-[#f2f1ee]">
          <div class="h-2 rounded-full bg-[#5b57d6]" style={"width: #{max(row.share, 1)}%"}></div>
        </div>
      </li>
    </ol>
    """
  end

  attr :posts, :list, required: true
  attr :empty, :string, required: true
  attr :figure, :any, required: true
  attr :tone, :any, default: nil

  @doc "A short list of posts, each with its status, publishing day and one figure on the right."
  def post_list(assigns) do
    ~H"""
    <.empty :if={@posts == []} icon="hero-document-text" text={@empty} />
    <ul :if={@posts != []} class="flex flex-col gap-2.5">
      <li
        :for={post <- @posts}
        class="flex items-center gap-3 rounded-[12px] border border-[#f0efea] bg-[#fdfdfc] px-4 py-3"
      >
        <div class="min-w-0 flex-1">
          <div class="truncate text-[12.5px] font-bold text-[#1b1a18]">{post.title}</div>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-[11px] font-medium text-[#a8a5a0]">
            <span class={[
              "rounded-md px-1.5 py-px text-[9px] font-bold uppercase tracking-[0.04em]",
              Home.status_tone(post.status)
            ]}>
              {Home.status_label(post.status)}
            </span>
            <span>{published_label(post)}</span>
          </div>
        </div>
        <div class={[
          "flex-none text-end font-['Space_Grotesk'] text-[14px] font-bold",
          (@tone && @tone.(post)) || "text-[#17161a]"
        ]}>
          {@figure.(post)}
        </div>
      </li>
    </ul>
    """
  end

  defp load_panels(socket, period) do
    socket = assign(socket, period: period, panels: empty_panels())

    case connected?(socket) do
      true -> Enum.reduce(Analytics.panels(), socket, &start_panel(&2, &1, period))
      false -> socket
    end
  end

  defp start_panel(socket, panel, period) do
    user = socket.assigns.current_user
    comments? = Home.holds?(socket.assigns.blog_areas, [:comment])

    MishkaGervaz.Messages.start_async(socket, {:panel, panel}, fn ->
      {period, Analytics.load(panel, user, period, comments?)}
    end)
  end

  defp empty_panels, do: Map.new(Analytics.panels(), &{&1, nil})

  defp xy(counts, peak) do
    last = max(length(counts) - 1, 1)
    top = max(peak, 1)

    counts
    |> Enum.with_index()
    |> Enum.map(fn {count, index} ->
      {round(index * @chart_width / last), round(@chart_height - count * @chart_height / top)}
    end)
  end

  defp polyline(points) do
    points
    |> Enum.map_join(" ", fn {x, y} -> "L#{x},#{y}" end)
    |> String.replace_prefix("L", "M")
  end

  # The area between two lines of counts: along `upper` left to right, back along `lower`.
  defp band(upper, lower, peak) do
    polyline(xy(upper, peak) ++ Enum.reverse(xy(lower, peak))) <> " Z"
  end

  defp all_time_note(0), do: gettext("No views recorded yet")
  defp all_time_note(_total), do: gettext("All time")

  defp readers_note(0), do: gettext("No readers in this period")
  defp readers_note(_visitors), do: gettext("Approximate across servers")

  defp trend(0, 0, days), do: gettext("Nothing in the last %{days} days", days: days)
  defp trend(_current, 0, _days), do: gettext("First views in this period")

  defp trend(current, previous, days),
    do:
      gettext("%{growth} vs previous %{days} days",
        growth: Home.growth(current, previous),
        days: days
      )

  defp engagement_note(0, 0, _days), do: gettext("No data")
  defp engagement_note(_rate, 0, _days), do: gettext("New")
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
end
