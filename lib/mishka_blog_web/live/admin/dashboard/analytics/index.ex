# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index do
  @moduledoc """
  The blog analytics page: KPI tiles; a views chart with Total, By category and Publishing tabs; a
  Top card with Bloggers, Categories, Tags, Teams and Commenters tabs; post age and weekday charts;
  comments over time and by status; and three post tables — every figure read from the daily view
  counts (`MishkaBlog.PostViewDaily`) and the comments by `MishkaBlog.Dashboard.Analytics`.

  The page shows only what is counted. There is no average read time, no bounce rate and no
  referrer here because nothing observes a reader leaving a post or keeps where they came from, and
  a tile that cannot be measured is worse than a tile that is missing. Unique Readers says it is
  approximate: each node of a site tells its readers apart on its own.

  ## The URL

  The period (7, 30 or 90 days), the Category, Tag, Blogger and Team filters, "Compare with previous
  period" and the Top Posts sort all live in the URL (`handle_params/3`), so a reload or a shared link
  opens the same view. The range buttons and the sort headers are patch links; a filter is gervaz's
  search select, whose pick patches the URL, its options read a page at a time, searched as they are
  typed (`MishkaBlog.Dashboard.Analytics.choices/3`).

  ## Loading

  The page draws first, every panel as a skeleton, then each panel of
  `MishkaBlog.Dashboard.Analytics.panels/0` is read in its own `start_async/3` and drawn when it
  lands, the hidden tabs' too, so switching a tab (`show_tab/3`, on the client) never waits. A
  changed period starts them all again; a result is only assigned while its period is still the one
  shown, so clicking through quickly cannot land an older read on top of a newer one. A new sort
  only reorders the posts already read.

  The charts are inline SVG built from the series — `xy/3` projects counts onto a fixed viewBox and
  `vector-effect="non-scaling-stroke"` keeps a stroke even once the box is stretched to the card.

  Number formatting is `MishkaBlogWeb.Live.Admin.Dashboard.Home.Index`'s — `growth/2`, `percent/2`,
  `move_tone/2`, `delta/2` and `status_tone/1` — so the overview and this page word the same figures
  identically; counts, dates and percentages are written in the reader's language by
  `MishkaCmsCore.Localized`.

  The page is a holder's of the blog's `admin:dashboard:blog:post` (`MishkaBlogWeb.SidebarMenu`).
  Every comment figure — the Engagement tile, the comments chart and card, the Commenters tab, a
  blogger's comments and a post's comments and engagement — is drawn only for a viewer who also
  holds `admin:dashboard:blog:comment`, and is not read for any other.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Logger

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, as: Home
  alias MishkaCmsCore.Localized
  alias Phoenix.LiveView.JS

  @chart_width 720
  @chart_height 180
  @gridlines [0, 45, 90, 135, 180]
  @sorts [:views, :readers, :comments, :engagement, :change]
  @closed_picker %{
    open?: false,
    search: "",
    options: [],
    more?: false,
    loading?: false,
    picked: nil
  }
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
    socket =
      socket
      |> assign(page_title: gettext("Blog Analytics"), period: nil, sort: :views)
      |> assign(blog_areas: Overview.areas(socket.assigns[:current_user]), panels: empty_panels())
      |> assign(:pickers, Map.new(Analytics.filters(), &{&1, @closed_picker}))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = Analytics.period(params)
    sort = Enum.find(@sorts, :views, &(to_string(&1) == params["sort"]))
    socket = assign(socket, :sort, sort)

    socket =
      case period == socket.assigns.period do
        true -> socket
        false -> socket |> load_panels(period) |> label_picked(period)
      end

    {:noreply, socket}
  end

  # The four filters are gervaz's search select (`search_select/1` of the blog's gervaz UI adapter),
  # whose events — `relation_*` — come to this page: their options are read a page at a time, off the
  # render, as they are opened, searched and scrolled.
  @impl true
  def handle_event("relation_focus", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      socket = put_picker(socket, kind, %{picker | open?: true})

      case picker.options == [] and not picker.loading? do
        true -> load_choices(socket, kind, picker.search, 0)
        false -> socket
      end
    end)
  end

  def handle_event("relation_search", %{"filter" => name} = params, socket) do
    with_picker(socket, name, fn kind, picker ->
      term = String.trim(params["value"] || "")
      term = (String.length(term) >= 2 && term) || ""

      case term == picker.search and picker.options != [] do
        true -> put_picker(socket, kind, %{picker | open?: true})
        false -> load_choices(socket, kind, term, 0)
      end
    end)
  end

  def handle_event("relation_load_more", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      load_choices(socket, kind, picker.search, length(picker.options))
    end)
  end

  def handle_event("relation_select", %{"filter" => name, "id" => id} = params, socket) do
    with_picker(socket, name, fn kind, picker ->
      period = socket.assigns.period
      period = %{period | filters: Map.put(period.filters, kind, id)}

      socket
      |> put_picker(kind, %{
        picker
        | open?: false,
          search: "",
          options: [],
          picked: {params["label"] || id, id}
      })
      |> push_patch(to: page_path(socket, period, socket.assigns.sort))
    end)
  end

  def handle_event("relation_close_dropdown", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      put_picker(socket, kind, %{picker | open?: false})
    end)
  end

  def handle_event("clear_filter", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, _picker ->
      period = socket.assigns.period
      period = %{period | filters: Map.delete(period.filters, kind)}

      push_patch(socket, to: page_path(socket, period, socket.assigns.sort))
    end)
  end

  def handle_event("compare", params, socket) do
    period = %{socket.assigns.period | compare: params["compare"] == "true"}

    {:noreply, push_patch(socket, to: page_path(socket, period, socket.assigns.sort))}
  end

  @impl true
  def handle_async({:panel, panel}, {:ok, {period, data}}, socket) do
    socket =
      (period == socket.assigns.period &&
         assign(socket, :panels, Map.put(socket.assigns.panels, panel, data))) || socket

    {:noreply, socket}
  end

  def handle_async({:choices, kind, term, offset}, {:ok, {options, more?}}, socket) do
    picker = socket.assigns.pickers[kind]

    socket =
      case picker.search == term do
        true ->
          options = (offset == 0 && options) || picker.options ++ options
          put_picker(socket, kind, %{picker | options: options, more?: more?, loading?: false})

        false ->
          socket
      end

    {:noreply, socket}
  end

  def handle_async({:picked, kind, id}, {:ok, {options, _more?}}, socket) do
    picker = socket.assigns.pickers[kind]

    socket =
      case {socket.assigns.period.filters[kind], options} do
        {^id, [{label, ^id}]} -> put_picker(socket, kind, %{picker | picked: {label, id}})
        _gone -> socket
      end

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

  @doc "The filter bar's fields, as `{key, label}`."
  @spec filter_fields() :: [{atom(), String.t()}]
  def filter_fields do
    [
      category: gettext("Category"),
      tag: gettext("Tag"),
      blogger: gettext("Blogger"),
      team: gettext("Team")
    ]
  end

  @doc """
  The assigns of the `kind` filter's search select, as gervaz's `search_select/1` takes them:
  `picker` is the page's state of that filter, and `value` the id the URL picked.
  """
  @spec picker_assigns(atom(), map(), String.t() | nil) :: map()
  def picker_assigns(kind, picker, value) do
    %{
      __changed__: %{},
      id: "analytics-filter-#{kind}",
      name: "filters[#{kind}]",
      filter_name: to_string(kind),
      table_id: "analytics",
      options: picker.options,
      value: value || "",
      selected_options: (picker.picked && value && [picker.picked]) || [],
      placeholder: gettext("All"),
      icon: "hero-magnifying-glass",
      search: true,
      has_more?: picker.more?,
      loading?: picker.loading?,
      dropdown_open?: picker.open?,
      search_term: picker.search,
      min_chars: 2,
      debounce: 300
    }
  end

  @doc "The search select of the blog's gervaz UI adapter, drawn from `picker_assigns/3`."
  @spec search_select(map()) :: Phoenix.LiveView.Rendered.t()
  def search_select(assigns),
    do: MishkaGervaz.Domain.Info.Table.ui_adapter(MishkaBlog).search_select(assigns)

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

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-chart-bar"
  attr :class, :string, default: nil

  slot :tab, required: true do
    attr :key, :string, required: true
    attr :label, :string, required: true
    attr :note, :string
    attr :loading, :boolean
  end

  @doc """
  A card of several panels under one title, one shown at a time: pill tabs, as the range switch
  draws them, switch between them on the client (`show_tab/3`), so a tab costs no round trip. Each
  tab's body is a skeleton until its data lands.
  """
  def tabbed(assigns) do
    assigns = assign(assigns, :keys, Enum.map(assigns.tab, & &1.key))

    ~H"""
    <section
      id={@id}
      data-role={@id}
      class={[
        "min-w-0 rounded-[18px] border border-[#ecebe6] bg-white px-[22px] py-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] max-[560px]:px-4!",
        @class
      ]}
    >
      <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-[11px]">
          <span class="grid size-8 flex-none place-items-center rounded-[9px] bg-[#f2f1fc] text-[#5b57d6]">
            <.icon name={@icon} class="size-4" />
          </span>
          <h2 class="font-['Space_Grotesk'] text-[16px] font-bold text-[#17161a]">{@title}</h2>
        </div>
        <div
          role="tablist"
          class="inline-flex max-w-full flex-wrap items-center gap-1 rounded-[12px] border border-[#ecebe6] bg-white p-1"
        >
          <button
            :for={{tab, index} <- Enum.with_index(@tab)}
            type="button"
            role="tab"
            id={"#{@id}-tab-#{tab.key}"}
            aria-selected={to_string(index == 0)}
            aria-controls={"#{@id}-#{tab.key}"}
            phx-click={show_tab(@id, tab.key, @keys)}
            class="h-8 rounded-[9px] px-3 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] aria-selected:bg-[#f2f1fc] aria-selected:text-[#4f4bcc]"
          >
            {tab.label}
          </button>
        </div>
      </div>
      <div
        :for={{tab, index} <- Enum.with_index(@tab)}
        id={"#{@id}-#{tab.key}"}
        data-role={"#{@id}-#{tab.key}"}
        role="tabpanel"
        class={index > 0 && "hidden"}
      >
        <div :if={tab[:note]} class="-mt-2 mb-3 text-[12px] font-medium text-[#8a877f]">
          {tab.note}
        </div>
        <div :if={tab[:loading]} class="flex animate-pulse flex-col gap-2.5">
          <div
            :for={w <- [86, 64, 72, 48]}
            class="h-3 rounded bg-[#f2f1ee]"
            style={"width: #{w}%"}
          >
          </div>
        </div>
        <div :if={!tab[:loading]}>{render_slot(tab)}</div>
      </div>
    </section>
    """
  end

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

  @doc "The comments list, filtered to `status` — where a Comments tile leads."
  @spec comments_path(Phoenix.LiveView.Socket.t(), atom()) :: String.t()
  def comments_path(socket, status),
    do:
      path(
        socket,
        "/admin/dashboard/blog/comments?" <>
          URI.encode_query(%{"comments_filter_status" => status})
      )

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

  defp with_picker(socket, name, fun) do
    case Enum.find(Analytics.filters(), &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      kind -> {:noreply, fun.(kind, socket.assigns.pickers[kind])}
    end
  end

  defp put_picker(socket, kind, picker),
    do: assign(socket, :pickers, Map.put(socket.assigns.pickers, kind, picker))

  defp load_choices(socket, kind, term, offset) do
    user = socket.assigns.current_user
    picker = socket.assigns.pickers[kind]
    picker = %{picker | search: term, loading?: true, open?: true}
    picker = (offset == 0 && %{picker | options: []}) || picker

    socket
    |> put_picker(kind, picker)
    |> MishkaGervaz.Messages.start_async({:choices, kind, term, offset}, fn ->
      Analytics.choices(kind, user, search: term, offset: offset)
    end)
  end

  # A filter the URL names is labelled off the render, as the list it was picked from labels it.
  defp label_picked(socket, period) do
    Enum.reduce(Analytics.filters(), socket, fn kind, socket ->
      label_one(socket, kind, period.filters[kind], socket.assigns.pickers[kind])
    end)
  end

  defp label_one(socket, kind, nil, picker), do: put_picker(socket, kind, %{picker | picked: nil})
  defp label_one(socket, _kind, id, %{picked: {_label, id}}), do: socket

  defp label_one(socket, kind, id, _picker) do
    user = socket.assigns.current_user

    (connected?(socket) &&
       MishkaGervaz.Messages.start_async(socket, {:picked, kind, id}, fn ->
         Analytics.choices(kind, user, id: id)
       end)) || socket
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
