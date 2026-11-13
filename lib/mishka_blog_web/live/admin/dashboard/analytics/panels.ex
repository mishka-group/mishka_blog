# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Panels do
  @moduledoc """
  What the blog analytics page draws: its panels, its filters, and the components that draw them.

  ## A panel

  `built_in/0` is the page's list of panels, in order, each a plain map:

      %{
        id: "views",                     # the card's DOM id is "analytics-views"
        title: "Views Over Time",        # nil draws the tab bare, with no card (the KPI tiles)
        icon: "hero-chart-bar",
        size: :full,                     # :full, :wide, :half or :narrow of the page's row
        tabs: [
          %{
            id: "total",
            label: "Total",
            note: "One point per day, over the last 30 days",
            needs: [:post],              # the blog areas the viewer must hold
            data: :overview,             # tabs naming one data are read once
            load: {MishkaBlog.Dashboard.Analytics, :read, [:overview]},
            component: &MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Panels.views_total/1
          }
        ]
      }

  A card with one tab draws no tab bar. A tab's `load` is called off the render, with the viewer,
  the period and whether the viewer holds the comment area after its own arguments
  (`MishkaBlog.Dashboard.Analytics.load/5`), and its `component` is called with `data` (`nil` only
  for a bare tab, until it lands), `period`, `sort`, `areas` and `socket`; a card shows a skeleton
  until its tab's data lands.

  ## A filter

  `filters/0` is the page's list of filters, each `%{id: "category", label: "Category", choices:
  {module, function, args}}`: `choices` is called with the viewer and `search:`/`offset:` (or
  `id:`) options after its `args`, and answers `{[{label, value}], more?}` — a page of gervaz search
  select options (`MishkaBlog.Dashboard.Analytics.choices/3`). The picked value is in the URL under
  the filter's id and in every panel's `period.filters`.

  ## The events

  The page hands both lists to its plugins when it opens, on `"blog:analytics:panels"` as
  `%{panels: panels, current_user: user}` and on `"blog:analytics:filters"` as
  `%{filters: filters, current_user: user}`; a plugin answers the same map with the list changed —
  a panel or a tab added, one taken out or moved, a filter added or taken out. Every tab's data then
  passes `"blog:analytics:panel"` (`MishkaBlog.Dashboard.Analytics.load/5`).

  ## Drawing

  The charts are inline SVG built from the series, projected onto a fixed viewBox, with
  `vector-effect="non-scaling-stroke"` keeping a stroke even once the box is stretched to the card.
  Number formatting is `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index`'s, so the overview and this
  page word the same figures identically; counts, dates and percentages are written in the reader's
  language by `MishkaCmsCore.Localized`.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents
  import MishkaCmsCore.Helpers, only: [path: 2]

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, as: Home
  alias MishkaCmsCore.Localized
  alias Phoenix.LiveView.JS

  @chart_width 720
  @chart_height 180
  @gridlines [0, 45, 90, 135, 180]
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

  @sizes %{
    full: "col-span-6",
    wide: "col-span-4 max-[980px]:col-span-6!",
    half: "col-span-3 max-[760px]:col-span-6!",
    narrow: "col-span-2 max-[980px]:col-span-6!"
  }

  @doc "The blog's own filters, in the order the filter bar shows them."
  @spec filters() :: [map()]
  def filters do
    for {id, label} <- [
          {"category", gettext("Category")},
          {"tag", gettext("Tag")},
          {"blogger", gettext("Blogger")},
          {"team", gettext("Team")}
        ],
        do: %{id: id, label: label, choices: {Analytics, :choices, [id]}}
  end

  @doc "The blog's own panels, in the order the page draws them."
  @spec built_in() :: [map()]
  def built_in do
    [
      %{id: "kpis", title: nil, size: :full, tabs: [tab("kpis", :overview, &kpis/1)]},
      %{
        id: "views",
        title: gettext("Views Over Time"),
        icon: "hero-chart-bar",
        size: :full,
        tabs: [
          tab("total", :overview, &views_total/1, gettext("Total"), gettext("One point per day")),
          tab(
            "categories",
            :categories,
            &views_categories/1,
            gettext("By category"),
            gettext("The five categories read most, and every other one together")
          ),
          tab(
            "publishing",
            :overview,
            &views_publishing/1,
            gettext("Publishing"),
            gettext("Posts published each week, under the week's views")
          )
        ]
      },
      %{
        id: "top",
        title: gettext("Top"),
        icon: "hero-trophy",
        size: :full,
        tabs: [
          tab("bloggers", :bloggers, &top_bloggers/1, gettext("Bloggers")),
          tab("categories", :categories, &top_categories/1, gettext("Categories")),
          tab("tags", :tags, &top_tags/1, gettext("Tags")),
          tab("teams", :teams, &top_teams/1, gettext("Teams")),
          tab("commenters", :commenters, &top_commenters/1, gettext("Commenters"), nil, [
            :post,
            :comment
          ])
        ]
      },
      card("post-age", gettext("Post Age"), "hero-clock", :half, :post_age, &post_age/1,
        note: gettext("Views of new posts against older ones")
      ),
      card("weekdays", gettext("Day of Week"), "hero-calendar", :half, :overview, &weekdays/1,
        note: gettext("Views by weekday over the period")
      ),
      card(
        "comments",
        gettext("Comments Over Time"),
        "hero-chat-bubble-left-right",
        :wide,
        :overview,
        &comments/1,
        note: gettext("Comments written each day"),
        needs: [:comment]
      ),
      card(
        "comment-status",
        gettext("Comments"),
        "hero-inbox-stack",
        :narrow,
        :comment_status,
        &comment_status/1,
        note: gettext("Written in this period, by status"),
        needs: [:comment]
      ),
      card(
        "top-posts",
        gettext("Top Performing Posts"),
        "hero-trophy",
        :full,
        :posts,
        &top_posts/1,
        note: gettext("Most-read posts of the period")
      ),
      card("rising", gettext("Rising Posts"), "hero-arrow-trending-up", :half, :posts, &rising/1,
        note: gettext("Biggest growth against the period before")
      ),
      card("quiet", gettext("Quiet Posts"), "hero-moon", :half, :posts, &quiet/1,
        note: gettext("Published, and almost nobody read them in this period")
      )
    ]
  end

  defp tab(id, data, component, label \\ nil, note \\ nil, needs \\ [:post]) do
    %{
      id: id,
      label: label,
      note: note,
      needs: needs,
      data: data,
      load: {Analytics, :read, [data]},
      component: component
    }
  end

  defp card(id, title, icon, size, data, component, opts) do
    %{
      id: id,
      title: title,
      icon: icon,
      size: size,
      tabs: [tab(id, data, component, nil, opts[:note], Keyword.get(opts, :needs, [:post]))]
    }
  end

  @doc """
  `panels` with only the tabs `areas` holds every need of, and without a panel left with none.
  """
  @spec visible([map()], Overview.areas()) :: [map()]
  def visible(panels, areas) do
    for panel <- panels,
        tabs = Enum.filter(panel.tabs, &Home.holds?(areas, Map.get(&1, :needs, []))),
        tabs != [],
        do: %{panel | tabs: tabs}
  end

  attr :panel, :map, required: true
  attr :data, :map, required: true
  attr :period, :map, required: true
  attr :sort, :atom, required: true
  attr :areas, :map, required: true
  attr :socket, :any, required: true

  @doc """
  One panel of the page: its tab drawn bare when it has no title, otherwise a card with a tab bar
  when it has several tabs — pill tabs switched on the client (`show_tab/3`) — each tab a skeleton
  until its data lands.
  """
  def panel(%{panel: %{title: nil, tabs: [tab | _]}} = assigns) do
    assigns = assign(assigns, :tab, tab)

    ~H"""
    <div id={"analytics-#{@panel.id}"} class={size_class(@panel)}>
      {draw(@tab, Map.get(@data, @tab.data), assigns)}
    </div>
    """
  end

  def panel(assigns) do
    assigns =
      assign(assigns,
        dom: "analytics-#{assigns.panel.id}",
        keys: Enum.map(assigns.panel.tabs, & &1.id)
      )

    ~H"""
    <section
      id={@dom}
      data-role={@dom}
      class={[
        "min-w-0 rounded-[18px] border border-[#ecebe6] bg-white px-[22px] py-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] max-[560px]:px-4!",
        size_class(@panel)
      ]}
    >
      <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-[11px]">
          <span class="grid size-8 flex-none place-items-center rounded-[9px] bg-[#f2f1fc] text-[#5b57d6]">
            <.icon name={Map.get(@panel, :icon) || "hero-chart-bar"} class="size-4" />
          </span>
          <h2 class="font-['Space_Grotesk'] text-[16px] font-bold text-[#17161a]">{@panel.title}</h2>
        </div>
        <div
          :if={length(@panel.tabs) > 1}
          role="tablist"
          class="inline-flex max-w-full flex-wrap items-center gap-1 rounded-[12px] border border-[#ecebe6] bg-white p-1"
        >
          <button
            :for={{tab, index} <- Enum.with_index(@panel.tabs)}
            type="button"
            role="tab"
            id={"#{@dom}-tab-#{tab.id}"}
            aria-selected={to_string(index == 0)}
            aria-controls={"#{@dom}-#{tab.id}"}
            phx-click={show_tab(@dom, tab.id, @keys)}
            class="h-8 rounded-[9px] px-3 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] aria-selected:bg-[#f2f1fc] aria-selected:text-[#4f4bcc]"
          >
            {tab.label}
          </button>
        </div>
      </div>
      <div
        :for={{tab, index} <- Enum.with_index(@panel.tabs)}
        id={"#{@dom}-#{tab.id}"}
        data-role={"#{@dom}-#{tab.id}"}
        role="tabpanel"
        class={index > 0 && "hidden"}
      >
        <div :if={tab[:note]} class="-mt-2 mb-3 text-[12px] font-medium text-[#8a877f]">
          {tab.note}
        </div>
        <div :if={is_nil(Map.get(@data, tab.data))} class="flex animate-pulse flex-col gap-2.5">
          <div
            :for={w <- [86, 64, 72, 48]}
            class="h-3 rounded bg-[#f2f1ee]"
            style={"width: #{w}%"}
          >
          </div>
        </div>
        <div :if={Map.get(@data, tab.data)}>{draw(tab, Map.get(@data, tab.data), assigns)}</div>
      </div>
    </section>
    """
  end

  defp size_class(panel), do: Map.get(@sizes, Map.get(panel, :size, :full), @sizes.full)

  defp draw(tab, data, assigns) do
    tab.component.(%{
      __changed__: nil,
      data: data,
      period: assigns.period,
      sort: assigns.sort,
      areas: assigns.areas,
      socket: assigns.socket
    })
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

  @doc """
  What Quiet Posts says when it lists none: that every published post was read only when some post
  was read at all; with no post read and none quiet, no published post matches the period.
  """
  @spec quiet_empty(map()) :: String.t()
  def quiet_empty(%{top: [], quiet: []}), do: gettext("No published post matches this period.")
  def quiet_empty(_posts), do: gettext("Every published post was read in this period.")

  @doc """
  `n` of something, worded for one or many in the reader's language and written with its digits:
  `counted(:views, 1)` is `"1 view"`, `counted(:views, 1200)` `"1.2K views"`.
  """
  @spec counted(atom(), non_neg_integer()) :: String.t()
  def counted(:views, n), do: ngettext("%{n} view", "%{n} views", n, n: Localized.compact(n))

  def counted(:views_in_period, n),
    do:
      ngettext("%{n} view in this period", "%{n} views in this period", n,
        n: Localized.compact(n)
      )

  def counted(:posts, n), do: ngettext("%{n} post", "%{n} posts", n, n: Localized.number(n))

  def counted(:posts_published, n),
    do: ngettext("%{n} post published", "%{n} posts published", n, n: Localized.number(n))

  def counted(:comments, n),
    do: ngettext("%{n} comment", "%{n} comments", n, n: Localized.number(n))

  def counted(:comments_in_period, n),
    do:
      ngettext("%{n} comment in this period", "%{n} comments in this period", n,
        n: Localized.number(n)
      )

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

  @doc "Shows the `key` tab of the tabbed card `id` and hides its other `keys`, on the client."
  @spec show_tab(String.t(), String.t(), [String.t()]) :: JS.t()
  def show_tab(id, key, keys) do
    shown =
      JS.set_attribute(JS.show(to: "##{id}-#{key}"), {"aria-selected", "true"},
        to: "##{id}-tab-#{key}"
      )

    Enum.reduce(keys -- [key], shown, fn other, js ->
      js
      |> JS.hide(to: "##{id}-#{other}")
      |> JS.set_attribute({"aria-selected", "false"}, to: "##{id}-tab-#{other}")
    end)
  end

  @doc "The Comments card's tiles, `{status, count}`, in the order of `MishkaBlog.Dashboard.Analytics.statuses/0`."
  @spec comment_tiles(map()) :: [{atom(), non_neg_integer()}]
  def comment_tiles(counts), do: Enum.map(Analytics.statuses(), &{&1, Map.fetch!(counts, &1)})

  @doc """
  The comments list, filtered to `status` and to the comments written in the period — where a
  Comments tile leads, so the list counts what the tile counts. The written range ends the day after
  the period: gervaz's date range reads its end as that day's first instant.
  """
  @spec comments_path(Phoenix.LiveView.Socket.t(), atom(), Analytics.period()) :: String.t()
  def comments_path(socket, status, period) do
    query =
      URI.encode_query(%{
        "comments_filter_status" => status,
        "comments_filter_written" => "#{period.from}~#{Date.add(period.to, 1)}"
      })

    path(socket, "/admin/dashboard/blog/comments?" <> query)
  end

  @doc "The word a comment status is shown as."
  @spec status_word(atom()) :: String.t()
  def status_word(:pending), do: gettext("Awaiting moderation")
  def status_word(:approved), do: gettext("Approved")
  def status_word(:flagged), do: gettext("Flagged")
  def status_word(:spam), do: gettext("Spam")

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

  @doc "The KPI tiles: an em dash in each until the overview lands."
  def kpis(assigns) do
    ~H"""
    <div
      data-role="analytics-kpis"
      class="mb-5 grid grid-cols-5 gap-4 max-[1180px]:grid-cols-3! max-[980px]:grid-cols-2!"
    >
      <div
        :for={
          {label, icon, tone, value, note, note_tone} <-
            kpi_cards(@data, @period.days, @areas)
        }
        class="rounded-2xl border border-[#ecebe6] bg-white px-5 py-[18px] shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
      >
        <div class="flex items-center gap-3 max-[560px]:flex-col! max-[560px]:items-start! max-[560px]:gap-2!">
          <span class={["grid size-10 flex-none place-items-center rounded-[11px]", tone]}>
            <.icon name={icon} class="size-[19px]" />
          </span>
          <div class="min-w-0 flex-1">
            <div class="truncate text-[11.5px] font-semibold text-[#8a877f]">{label}</div>
            <div
              :if={@data}
              class="mt-0.5 font-['Space_Grotesk'] text-[24px] font-semibold leading-[1.1] tracking-[-0.02em] text-[#17161a]"
            >
              {value}
            </div>
            <div
              :if={!@data}
              class="mt-[7px] h-[19px] w-[58%] animate-pulse rounded bg-[#eeedea]"
            >
            </div>
          </div>
        </div>
        <div
          :if={@data}
          class={["mt-[11px] text-[11px] font-semibold leading-snug", note_tone]}
        >
          {note}
        </div>
        <div
          :if={!@data}
          class="mt-[13px] h-2.5 w-[44%] animate-pulse rounded bg-[#f2f1ee]"
        >
        </div>
      </div>
    </div>
    """
  end

  @doc "Views Over Time, Total: the daily views, and the window before beside them when compared."
  def views_total(assigns) do
    ~H"""
    <.empty
      :if={@data && @data.views_window == 0}
      text={gettext("No views recorded in the last %{days} days.", days: @period.days)}
    />

    <%!-- The viewBox is stretched to the card, so every stroke carries `non-scaling-stroke` — without
            it the line thins out as the card widens. --%>
    <div :if={@data && @data.views_window > 0}>
      <svg
        viewBox={view_box()}
        preserveAspectRatio="none"
        role="img"
        aria-label={chart_label(@data)}
        class="h-[180px] w-full"
      >
        <line
          :for={y <- gridlines()}
          x1="0"
          y1={y}
          x2={chart_width()}
          y2={y}
          stroke="#f0efea"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />
        <path
          d={
            area_path(
              @data.series,
              chart_peak(
                @data.series,
                @data.previous_series,
                @period.compare
              )
            )
          }
          fill="#eef1fc"
        />
        <path
          :if={@period.compare}
          data-role="previous-line"
          d={
            line_path(
              @data.previous_series,
              chart_peak(
                @data.series,
                @data.previous_series,
                @period.compare
              )
            )
          }
          fill="none"
          stroke="#a8a5a0"
          stroke-width="1.5"
          stroke-dasharray="5 4"
          vector-effect="non-scaling-stroke"
        />
        <path
          d={
            line_path(
              @data.series,
              chart_peak(
                @data.series,
                @data.previous_series,
                @period.compare
              )
            )
          }
          fill="none"
          stroke="#5b57d6"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
      </svg>

      <div class="mt-2.5 flex flex-wrap items-center justify-between gap-2 text-[11px] font-medium text-[#a8a5a0]">
        <span>{day_label(@period.from)}</span>
        <span :if={@period.compare} class="inline-flex items-center gap-1.5">
          <span class="inline-block h-0 w-4 border-t-2 border-dashed border-[#a8a5a0]"></span>
          {gettext("Previous %{days} days: %{views}",
            days: @period.days,
            views: Localized.compact(@data.views_previous)
          )}
        </span>
        <span :if={!@period.compare}>
          {counted(:views_in_period, @data.views_window)}
        </span>
        <span>{day_label(@period.to)}</span>
      </div>
    </div>
    """
  end

  @doc "Views Over Time, By category: the five categories read most and every other one, stacked."
  def views_categories(assigns) do
    ~H"""
    <.empty
      :if={@data && @data.top == []}
      text={gettext("No category was read in this period.")}
    />
    <div :if={@data && @data.top != []}>
      <svg
        viewBox={view_box()}
        preserveAspectRatio="none"
        role="img"
        aria-label={gettext("Daily views stacked by category")}
        class="h-[180px] w-full"
      >
        <path
          :for={
            {_key, colour, d} <-
              stack_paths(@data.series, stack_keys(@data))
          }
          d={d}
          fill={colour}
          fill-opacity="0.85"
        />
      </svg>
      <ul class="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 text-[11.5px] font-semibold text-[#6d6a63]">
        <li
          :for={{key, index} <- Enum.with_index(stack_keys(@data))}
          class="inline-flex items-center gap-1.5"
        >
          <span class="size-2.5 rounded-sm" style={"background: #{layer_colour(index)}"}></span>
          {layer_name(@data, key)}
        </li>
      </ul>
    </div>
    """
  end

  @doc "Views Over Time, Publishing: posts published each week under the week's views."
  def views_publishing(assigns) do
    ~H"""
    <div :if={@data}>
      <div class="relative h-[140px]">
        <div class="absolute inset-0 flex items-end gap-1.5">
          <div
            :for={week <- @data.weeks}
            class="flex h-full flex-1 flex-col justify-end"
            title={
                counted(:posts, week.posts) <> ", " <> counted(:views, week.views)
              }
          >
            <div
              class="rounded-t bg-[#dcdbf5]"
              style={"height: #{bar_height(week.posts, peak_of(@data.weeks, :posts))}%"}
            >
            </div>
          </div>
        </div>
        <svg
          viewBox={view_box()}
          preserveAspectRatio="none"
          role="img"
          aria-label={gettext("Weekly views over posts published")}
          class="absolute inset-0 h-full w-full"
        >
          <path
            d={weeks_line(@data.weeks)}
            fill="none"
            stroke="#1f9d6b"
            stroke-width="2"
            vector-effect="non-scaling-stroke"
          />
        </svg>
      </div>
      <div class="mt-2.5 flex flex-wrap justify-between gap-2 text-[11px] font-medium text-[#a8a5a0]">
        <span class="inline-flex items-center gap-1.5">
          <span class="size-2.5 rounded-sm bg-[#dcdbf5]"></span>{gettext("Posts published")}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block h-0.5 w-3 bg-[#1f9d6b]"></span>{gettext("Views")}
        </span>
      </div>
    </div>
    """
  end

  @doc "Top, Bloggers: views, posts published and, for the comment area, comments received."
  def top_bloggers(assigns) do
    ~H"""
    <.empty :if={@data == []} text={gettext("No blogger was read in this period.")} />
    <ol :if={@data not in [nil, []]} class="flex flex-col gap-2.5">
      <li
        :for={blogger <- @data}
        class="rounded-[12px] border border-[#f0efea] bg-[#fdfdfc] px-3.5 py-2.5"
      >
        <div class="truncate text-[12.5px] font-bold text-[#1b1a18]">{name_of(blogger)}</div>
        <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-[11px] font-semibold text-[#8a877f]">
          <span>{counted(:views, blogger.views)}</span>
          <span>{counted(:posts_published, blogger.posts)}</span>
          <span :if={Home.holds?(@areas, [:comment])}>
            {counted(:comments, blogger.comments || 0)}
          </span>
        </div>
      </li>
    </ol>
    """
  end

  @doc "Top, Categories: views and share."
  def top_categories(assigns) do
    ~H"""
    <.bar_list
      :if={@data}
      rows={@data.top}
      empty={gettext("No category was read in this period.")}
    />
    """
  end

  @doc "Top, Tags: views and share."
  def top_tags(assigns) do
    ~H"""
    <.bar_list
      :if={@data}
      rows={@data}
      empty={gettext("No tag was read in this period.")}
    />
    """
  end

  @doc "Top, Teams: views and share, a co-written post counted once."
  def top_teams(assigns) do
    ~H"""
    <.bar_list
      :if={@data}
      rows={@data}
      empty={gettext("No team was read in this period.")}
    />
    """
  end

  @doc "Top, Commenters: who wrote the most comments."
  def top_commenters(assigns) do
    ~H"""
    <.empty
      :if={@data == []}
      icon="hero-user"
      text={gettext("No comment in this period.")}
    />
    <ol :if={@data not in [nil, []]} class="flex flex-col gap-2">
      <li
        :for={row <- @data}
        class="flex items-center justify-between gap-3 text-[12.5px]"
      >
        <span class="min-w-0 truncate font-semibold text-[#1b1a18]">{commenter(row.comment)}</span>
        <span class="flex-none font-semibold text-[#6d6a63]">{Localized.number(row.count)}</span>
      </li>
    </ol>
    """
  end

  @doc "Post Age: views of posts published in the last 30 days against older ones."
  def post_age(assigns) do
    ~H"""
    <div :if={@data}>
      <.empty
        :if={post_age_total(@data) == 0}
        text={gettext("No views recorded in the last %{days} days.", days: @period.days)}
      />
      <div :if={post_age_total(@data) > 0}>
        <div class="flex h-3 overflow-hidden rounded-full bg-[#f2f1ee]">
          <div
            class="bg-[#5b57d6]"
            style={"width: #{round(@data.fresh * 100 / post_age_total(@data))}%"}
          >
          </div>
          <div
            class="bg-[#c3c0b8]"
            style={"width: #{round(@data.older * 100 / post_age_total(@data))}%"}
          >
          </div>
        </div>
        <dl class="mt-4 grid grid-cols-2 gap-3">
          <div>
            <dt class="text-[11.5px] font-semibold text-[#8a877f]">
              {gettext("Published in the last %{days} days", days: @data.fresh_days)}
            </dt>
            <dd class="mt-1 font-['Space_Grotesk'] text-[20px] font-bold text-[#5b57d6]">
              {Localized.compact(@data.fresh)}
            </dd>
          </div>
          <div>
            <dt class="text-[11.5px] font-semibold text-[#8a877f]">{gettext("Older")}</dt>
            <dd class="mt-1 font-['Space_Grotesk'] text-[20px] font-bold text-[#6d6a63]">
              {Localized.compact(@data.older)}
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  @doc "Day of Week: views by weekday over the period."
  def weekdays(assigns) do
    ~H"""
    <.empty
      :if={@data && @data.views_window == 0}
      text={gettext("No views recorded in the last %{days} days.", days: @period.days)}
    />
    <div :if={@data && @data.views_window > 0}>
      <div class="flex h-[140px] items-end gap-2">
        <div
          :for={day <- @data.weekdays}
          class="flex h-full flex-1 flex-col items-center justify-end gap-1.5"
        >
          <span class="text-[10.5px] font-semibold text-[#8a877f]">{Localized.compact(day.count)}</span>
          <div
            class="w-full rounded-t bg-[#5b57d6]"
            style={"height: #{bar_height(day.count, peak_of(@data.weekdays, :count))}%"}
          >
          </div>
        </div>
      </div>
      <div class="mt-2 flex gap-2 text-center text-[11px] font-semibold text-[#a8a5a0]">
        <span :for={day <- @data.weekdays} class="flex-1">{weekday_label(day.day)}</span>
      </div>
    </div>
    """
  end

  @doc "Comments Over Time: comments written each day."
  def comments(assigns) do
    ~H"""
    <div :if={@data && @data.comments}>
      <.empty
        :if={@data.comments.window == 0}
        icon="hero-chat-bubble-left"
        text={gettext("No comment in this period.")}
      />
      <svg
        :if={@data.comments.window > 0}
        viewBox={view_box()}
        preserveAspectRatio="none"
        role="img"
        aria-label={counted(:comments_in_period, @data.comments.window)}
        class="h-[150px] w-full"
      >
        <path
          :if={@period.compare}
          d={
            line_path(
              @data.comments.previous_series,
              chart_peak(
                @data.comments.series,
                @data.comments.previous_series,
                @period.compare
              )
            )
          }
          fill="none"
          stroke="#a8a5a0"
          stroke-width="1.5"
          stroke-dasharray="5 4"
          vector-effect="non-scaling-stroke"
        />
        <path
          d={
            line_path(
              @data.comments.series,
              chart_peak(
                @data.comments.series,
                @data.comments.previous_series,
                @period.compare
              )
            )
          }
          fill="none"
          stroke="#3a6cb5"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <div
        :if={@data.comments.window > 0}
        class="mt-2 text-[11px] font-medium text-[#a8a5a0]"
      >
        {counted(:comments_in_period, @data.comments.window)}
        <span :if={@period.compare}>
          · {gettext("%{count} in the previous %{days} days",
            count: Localized.number(@data.comments.previous),
            days: @period.days
          )}
        </span>
      </div>
    </div>
    """
  end

  @doc "Comments: the period's comments by status, each a link to the comments list filtered to it."
  def comment_status(assigns) do
    ~H"""
    <div :if={@data} class="grid grid-cols-2 gap-2.5">
      <.link
        :for={{status, count} <- comment_tiles(@data)}
        id={"analytics-comments-#{status}"}
        navigate={comments_path(@socket, status, @period)}
        class="rounded-[12px] border border-[#f0efea] bg-[#fdfdfc] px-3.5 py-3 transition-colors hover:border-[#dcdbf5]"
      >
        <div class="text-[11.5px] font-semibold text-[#8a877f]">{status_word(status)}</div>
        <div class="mt-1 font-['Space_Grotesk'] text-[20px] font-bold text-[#17161a]">
          {Localized.number(count)}
        </div>
      </.link>
    </div>
    """
  end

  @doc "Top Performing Posts: a table sorted by the URL's `sort`."
  def top_posts(assigns) do
    ~H"""
    <.empty
      :if={@data && @data.top == []}
      icon="hero-document-text"
      text={gettext("No post was opened in this period.")}
    />
    <div :if={@data && @data.top != []} class="-mx-1 overflow-x-auto">
      <table class="w-full min-w-[560px] text-[12.5px]">
        <thead>
          <tr class="text-[11px] font-semibold text-[#8a877f]">
            <th class="px-1 py-2 text-start">{gettext("Post")}</th>
            <th :for={{key, label} <- sorts(@areas)} class="px-1 py-2 text-end">
              <.link
                id={"analytics-sort-#{key}"}
                patch={page_path(@socket, @period, key)}
                aria-sort={(key == @sort && "descending") || "none"}
                class={[
                  "inline-flex items-center gap-1",
                  (key == @sort && "text-[#4f4bcc]") || "hover:text-[#1b1a18]"
                ]}
              >
                {label}
                <.icon :if={key == @sort} name="hero-chevron-down" class="size-3" />
              </.link>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={post <- Analytics.sort_posts(@data.top, @sort)}
            class="border-t border-[#f0efea]"
          >
            <td class="max-w-[280px] px-1 py-2.5">
              <div class="truncate font-bold text-[#1b1a18]">{post.title}</div>
              <div class="mt-0.5 text-[11px] font-medium text-[#a8a5a0]">
                {published_label(post)}
              </div>
            </td>
            <td class="px-1 text-end font-semibold">{Localized.compact(post.views)}</td>
            <td class="px-1 text-end font-semibold">{Localized.compact(post.readers)}</td>
            <td :if={Home.holds?(@areas, [:comment])} class="px-1 text-end font-semibold">
              {Localized.number(post.comments || 0)}
            </td>
            <td :if={Home.holds?(@areas, [:comment])} class="px-1 text-end font-semibold">
              {Home.percent(post.engagement || 0)}
            </td>
            <td class={["px-1 text-end font-semibold", change_tone(post.change)]}>
              {change_label(post.change)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Rising Posts: the biggest growth against the window before."
  def rising(assigns) do
    ~H"""
    <.post_list
      :if={@data}
      posts={@data.rising}
      empty={gettext("No post grew in this period.")}
      figure={&change_label(&1.change)}
      tone={&change_tone(&1.change)}
    />
    """
  end

  @doc "Quiet Posts: published posts almost nobody read."
  def quiet(assigns) do
    ~H"""
    <.post_list
      :if={@data}
      posts={@data.quiet}
      empty={quiet_empty(@data)}
      figure={&counted(:views, &1.views)}
    />
    """
  end

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
