# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Home.Index do
  @moduledoc """
  The blog admin overview: five KPI cards, eight section cards, an editorial calendar and three
  summary panels, every number read from the database by `MishkaBlog.Dashboard.Overview`.

  Both reads run off the render in a `start_async/3` — between them they issue thirty-odd counts, so
  the page paints its labels and links first and fills the numbers in when they land. Until then
  every figure is an em dash: `kpi_cards/1`, `section_cards/1` and `month_rows/1` each have a `nil`
  clause over the same shared metadata, which is why there is no second skeleton markup to keep in
  step with the real one. The calendar is only read when its panel is first opened, and again on
  each month change, so a visitor who never opens it never pays for it. A calendar result is only
  assigned when its month is still the selected one, so paging quickly cannot land an older read on
  top of a newer one.

  Everything from `kpi_cards/1` down is presentation: `delta/2`, `growth/2` and `percent/2` turn raw
  counts into the labels the design shows, and every number, date and time is written in the reader's
  language by `MishkaCmsCore.Localized`. `MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed`
  supplies the "Logs" panel and the Calendar toggle rides in its `:toggles` slot, so both controls
  sit on one row as the design has them.

  ## What each viewer is shown

  The blog has two areas (`MishkaBlog.Dashboard.Overview.areas/1`): a holder of `admin:dashboard:blog:post` is
  shown the posts, bloggers, collections, tags, teams, auto posting and views — the calendar and the
  Logs panel included — and a holder of `admin:dashboard:blog:comment` the comments. The Engagement
  figures divide comments by views, so they need both. A card, a row or a link whose area the
  viewer does not hold is not drawn, and `MishkaBlog.Dashboard.Overview` does not read its data.

  A figure counted from the view log (`untracked?/1`) carries a "Not tracked yet" label, and the
  Auto Posting and Analytics cards (`on_roadmap?/1`) an "On our roadmap" one, both drawn by
  `roadmap_badge/1`: nothing records a view yet, and those two sections are not built.

  Setting the blog up, the Doctor and the kit upgrade write pages, components and a snippet, and
  read the site they are for, so they need all three of `admin:dashboard:runtime:page` (the pages
  and the page builder's snippet), `admin:dashboard:runtime:component` and
  `admin:dashboard:runtime:site`.

  See `MishkaBlog.Dashboard.Overview` for the queries.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Logger

  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlog.Kit
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.{ExtensionProvision, Site}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel
  alias MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel
  alias MishkaCmsCoreWeb.Templates.CardChrome

  require Ash.Query

  # WHAT THE BUTTON WRITES IS WHAT GATES IT, every name of it, as the provision itself asks
  # (`ExtensionProvision.allowed?/2`): setting a site up (and the Doctor's Repair) writes components,
  # pages and the sidebar snippet, and reads the site; the kit check and upgrade read the site and
  # its pages and write components. This is asked again in `handle_event/3`, because hiding a button
  # hides nothing from a socket.
  @blog_resources [
    MishkaBlog.BlogPost,
    MishkaBlog.Collection,
    MishkaBlog.Team,
    MishkaBlog.Blogger,
    MishkaBlog.Tag
  ]

  @a_sunday ~D[2023-01-01]

  @body "text-[#1b1a18]"
  @muted "text-[#8a877f]"
  @up "text-[#177a53]"
  @down "text-[#b3433a]"
  @warn "text-[#c0752a]"
  @waiting "text-[#a8a5a0]"

  @kpis [
    {gettext_noop("Today's Posts"), "hero-document-text", "bg-[#eaf1fb] text-[#3a6cb5]", [:post]},
    {gettext_noop("Today's Views"), "hero-eye", "bg-[#eaf6ee] text-[#1f9d6b]", [:post]},
    {gettext_noop("New Comments"), "hero-chat-bubble-left-right", "bg-[#f1edfb] text-[#7a5bd0]",
     [:comment]},
    {gettext_noop("Active Bloggers"), "hero-user-circle", "bg-[#fbf1e5] text-[#c07a2a]", [:post]},
    {gettext_noop("Engagement"), "hero-arrow-trending-up", "bg-[#eef1fc] text-[#4f4bcc]",
     [:post, :comment]}
  ]

  @sections [
    {gettext_noop("Collections"), gettext_noop("Organize posts into themed collections"),
     "/admin/dashboard/blog/collections", "hero-folder", "bg-[#eaf1fb] text-[#3a6cb5]",
     {gettext_noop("Total Collections"), gettext_noop("Posts Organized")}, [:post]},
    {gettext_noop("Blog Posts"), gettext_noop("Create and manage your content"),
     "/admin/dashboard/blog/posts", "hero-document-text", "bg-[#eaf6ee] text-[#1f9d6b]",
     {gettext_noop("Published"), gettext_noop("Drafts")}, [:post]},
    {gettext_noop("Bloggers"), gettext_noop("Manage content creators"),
     "/admin/dashboard/blog/bloggers", "hero-user-circle", "bg-[#f1edfb] text-[#7a5bd0]",
     {gettext_noop("Active Authors"), gettext_noop("Publishers")}, [:post]},
    {gettext_noop("Teams"), gettext_noop("Editorial team collaboration"),
     "/admin/dashboard/blog/teams", "hero-user-group", "bg-[#fbf1e5] text-[#c07a2a]",
     {gettext_noop("Active Teams"), gettext_noop("Team Members")}, [:post]},
    {gettext_noop("Comments"), gettext_noop("Moderate user feedback"),
     "/admin/dashboard/blog/comments", "hero-chat-bubble-left-right",
     "bg-[#eaf1fb] text-[#3a6cb5]", {gettext_noop("Total Comments"), gettext_noop("Pending")},
     [:comment]},
    {gettext_noop("Auto Posting"), gettext_noop("Schedule and automate publishing"),
     "/admin/dashboard/blog/auto-posting", "hero-calendar-days", "bg-[#e6f5f2] text-[#1f8f86]",
     {gettext_noop("Scheduled Posts"), gettext_noop("Active Rules")}, [:post]},
    {gettext_noop("Tags"), gettext_noop("Organize content with tags"),
     "/admin/dashboard/blog/tags", "hero-hashtag", "bg-[#eaf6ee] text-[#1f9d6b]",
     {gettext_noop("Total Tags"), gettext_noop("Most Used")}, [:post]},
    {gettext_noop("Analytics"), gettext_noop("Detailed performance insights"),
     "/admin/dashboard/blog/analytics", "hero-arrow-trending-up", "bg-[#fbf6e5] text-[#b59321]",
     {gettext_noop("Total Views"), gettext_noop("Growth Rate")}, [:post]}
  ]

  # THE FIGURES COUNTED FROM THE VIEW LOG, which nothing writes to yet, and the sections that are
  # not built yet — the cards, rows and tiles that carry a roadmap label.
  @untracked_figures ["Today's Views", "Engagement", "Total Views", "Engagement Rate"]
  @roadmap_sections ["Auto Posting", "Analytics"]

  @month_labels [
    {gettext_noop("Posts Published"), [:post]},
    {gettext_noop("Total Views"), [:post]},
    {gettext_noop("New Comments"), [:comment]},
    {gettext_noop("Engagement Rate"), [:post, :comment]}
  ]

  @quick_actions [
    {gettext_noop("Create New Post"), "hero-plus", "/admin/dashboard/blog/posts", true, [:post]},
    {gettext_noop("Review Comments"), "hero-chat-bubble-left-right",
     "/admin/dashboard/blog/comments", false, [:comment]},
    {gettext_noop("View Analytics"), "hero-arrow-trending-up", "/admin/dashboard/blog/analytics",
     false, [:post]},
    {gettext_noop("Blog Settings"), "hero-cog-6-tooth", "/admin/dashboard/settings?tab=blog",
     false, []}
  ]

  @impl true
  def mount(_params, session, socket) do
    today = Date.utc_today()
    areas = Overview.areas(socket.assigns[:current_user])

    socket =
      socket
      |> assign(:blog_areas, areas)
      |> activity_feed(areas)
      |> assign(
        page_title: "MishkaBlog",
        stats: nil,
        calendar: nil,
        show_calendar: false,
        month: Date.beginning_of_month(today),
        selected_date: today
      )
      |> assign_provision(session)
      |> ExtensionInstallerPanel.setup(app: :mishka_blog, noun: gettext("blog"))
      |> then(&ExtensionInstallerPanel.start_on(&1, &1.assigns.provision_site_id))
      |> gate()
      |> KitUpgradePanel.setup(
        bundle: Kit.bundle_path(),
        noun: gettext("blog components"),
        pages: &MishkaBlog.Provision.sample_pages/2,
        draft_label: gettext("Blog sample page")
      )
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "toggle_calendar",
        _params,
        %{assigns: %{blog_areas: %{post: false}}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("toggle_calendar", _params, socket) do
    socket = update(socket, :show_calendar, &(!&1))

    {:noreply, (socket.assigns.show_calendar && load_calendar(socket)) || socket}
  end

  def handle_event("shift_month", %{"step" => step}, socket) do
    month = shift_month(socket.assigns.month, String.to_integer(step))
    selected = same_day_in(month, socket.assigns.selected_date)

    socket =
      socket
      |> assign(month: month, selected_date: selected, calendar: nil)
      |> load_calendar()

    {:noreply, socket}
  end

  def handle_event("this_month", _params, socket) do
    today = Date.utc_today()

    socket =
      socket
      |> assign(month: Date.beginning_of_month(today), selected_date: today, calendar: nil)
      |> load_calendar()

    {:noreply, socket}
  end

  def handle_event("select_day", %{"date" => date}, socket) do
    {:noreply, assign(socket, :selected_date, Date.from_iso8601!(date))}
  end

  def handle_event("extension_install", params, socket) do
    allowed? = socket.assigns.may_provision?

    {:noreply,
     gate(ExtensionInstallerPanel.install(socket, chosen_site(socket, params), allowed?))}
  end

  def handle_event("extension_site", params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.choose(socket, chosen_site(socket, params)))}
  end

  # THE ANSWER TO A CLASH, which is the same install with the addresses the admin chose — so a
  # second run writes what the first could not and leaves everything else exactly as it was.
  def handle_event("extension_retry", params, socket) do
    allowed? = socket.assigns.may_provision?
    answers = Map.take(params, ["paths", "prefix"])

    {:noreply,
     gate(ExtensionInstallerPanel.install(socket, chosen_site(socket, params), allowed?, answers))}
  end

  def handle_event("extension_open", _params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.open(socket))}
  end

  def handle_event("extension_skip", _params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.close(socket))}
  end

  # THE SAME TWO QUESTIONS REPAIR ASKS, and the same answers: which site, and may this
  # admin write its runtime. Everything after them — what is outdated, what carries an edit, what is
  # written — is `MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel`, so the document dashboard
  # says all of it in the same words.
  # ONE PICKER FOR THE WHOLE MODAL, so the Repair button under the standings writes to the site
  # those standings are about. Both halves are told the same answer here rather than each keeping
  # its own, which is how a master could read one site and repair another.
  def handle_event("kit_check", params, socket) do
    site_id = chosen_site(socket, params)

    {:noreply,
     socket
     |> ExtensionInstallerPanel.choose(site_id)
     |> KitUpgradePanel.check(site_id, socket.assigns.may_provision?)}
  end

  def handle_event("kit_upgrade", %{"mode" => mode}, socket) do
    {:noreply, KitUpgradePanel.upgrade(socket, mode, socket.assigns.may_provision?)}
  end

  def handle_event("page_drafts", _params, socket) do
    {:noreply, KitUpgradePanel.offer(socket, socket.assigns.may_provision?)}
  end

  @impl true
  def handle_async(:stats, {:ok, stats}, socket) do
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_async(:calendar, {:ok, %{month: month} = calendar}, socket) do
    {:noreply, (month == socket.assigns.month && assign(socket, :calendar, calendar)) || socket}
  end

  def handle_async(name, {:exit, reason}, socket) do
    Logger.error("blog overview #{name} failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  @doc """
  The KPI cards `areas` may see, as `{label, icon, icon_tone, value, note, note_tone}` — of the
  five, those whose blog areas `areas` (`MishkaBlog.Dashboard.Overview.areas/1`) holds.

  The `nil` clause is what the page renders until `MishkaBlog.Dashboard.Overview.load/1` returns.
  """
  @spec kpi_cards(map() | nil, Overview.areas()) ::
          [{String.t(), String.t(), String.t(), String.t(), String.t(), String.t()}]
  def kpi_cards(stats, areas) do
    for {label, icon, tone, needs} <- @kpis, holds?(areas, needs) do
      {value, note, note_tone} = kpi(label, stats)
      {translate(label), icon, tone, value, note, note_tone}
    end
  end

  defp kpi(_label, nil), do: {"—", "…", @waiting}

  defp kpi("Today's Posts", stats),
    do:
      {Localized.compact(stats.posts_today), delta(stats.posts_today, stats.posts_yesterday),
       move_tone(stats.posts_today, stats.posts_yesterday)}

  defp kpi("Today's Views", stats),
    do:
      {Localized.compact(stats.views_today), views_note(stats.views_today, stats.views_yesterday),
       move_tone(stats.views_today, stats.views_yesterday)}

  defp kpi("New Comments", stats),
    do:
      {Localized.compact(stats.comments_recent), pending_note(stats.comments_pending),
       pending_tone(stats.comments_pending)}

  defp kpi("Active Bloggers", stats),
    do: {Localized.compact(stats.bloggers_active), joined_note(stats.bloggers_new), @muted}

  defp kpi("Engagement", stats),
    do:
      {percent(stats.engagement_rate), points(stats.engagement_rate, stats.engagement_previous),
       move_tone(stats.engagement_rate, stats.engagement_previous)}

  @doc """
  The destination cards `areas` may open, as `{title, description, link, icon, icon_tone, rows}`,
  where each row is `{label, value, value_tone}` — of the eight, those whose blog areas `areas`
  holds.
  """
  @spec section_cards(map() | nil, Overview.areas()) :: [
          {String.t(), String.t(), String.t(), String.t(), String.t(),
           [{String.t(), String.t(), String.t()}]}
        ]
  def section_cards(stats, areas) do
    for {title, description, link, icon, tone, {first, second}, needs} <- @sections,
        holds?(areas, needs) do
      {value, value_tone, other, other_tone} = section(title, stats)

      {translate(title), translate(description), link, icon, tone,
       [{translate(first), value, value_tone}, {translate(second), other, other_tone}]}
    end
  end

  defp section(_title, nil), do: {"—", @waiting, "—", @waiting}

  defp section("Collections", stats),
    do:
      {Localized.compact(stats.collections_total), @body,
       Localized.compact(stats.posts_organised), @body}

  defp section("Blog Posts", stats),
    do:
      {Localized.compact(stats.posts_published), @body, Localized.compact(stats.posts_drafts),
       @body}

  defp section("Bloggers", stats),
    do:
      {Localized.compact(stats.bloggers_active), @body,
       Localized.compact(stats.bloggers_publishers), @body}

  defp section("Teams", stats),
    do:
      {Localized.compact(stats.teams_active), @body, Localized.compact(stats.team_members), @body}

  defp section("Comments", stats),
    do:
      {Localized.compact(stats.comments_total), @body, Localized.compact(stats.comments_pending),
       pending_tone(stats.comments_pending)}

  defp section("Auto Posting", stats),
    do:
      {Localized.compact(stats.posts_scheduled), @body, Localized.compact(stats.automation_rules),
       @body}

  defp section("Tags", stats),
    do: {Localized.compact(stats.tags_total), @body, stats.tags_top || "—", @body}

  defp section("Analytics", stats),
    do:
      {Localized.compact(stats.views_total), @body,
       growth(stats.views_window, stats.views_previous),
       move_tone(stats.views_window, stats.views_previous)}

  @doc """
  The rows of the This Month panel `areas` may see, as `{label, value, value_tone}`.
  """
  @spec month_rows(map() | nil, Overview.areas()) :: [{String.t(), String.t(), String.t()}]
  def month_rows(stats, areas) do
    for {label, needs} <- @month_labels, holds?(areas, needs) do
      {value, tone} = month(label, stats)
      {translate(label), value, tone}
    end
  end

  defp month(_label, nil), do: {"—", @waiting}
  defp month("Posts Published", stats), do: {Localized.compact(stats.month_posts), @body}
  defp month("Total Views", stats), do: {Localized.compact(stats.month_views), @body}
  defp month("New Comments", stats), do: {Localized.compact(stats.month_comments), @body}
  defp month("Engagement Rate", stats), do: {percent(stats.month_engagement), @up}

  @doc "The Quick Actions rows `areas` may follow, as `{label, icon, path, primary?}`."
  @spec quick_actions(Overview.areas()) ::
          [{String.t(), String.t(), String.t(), boolean()}]
  def quick_actions(areas) do
    for {label, icon, path, primary?, needs} <- @quick_actions,
        holds?(areas, needs),
        do: {translate(label), icon, path, primary?}
  end

  @doc """
  Whether `label`, as a KPI tile or a This Month row shows it, is a figure counted from the view log.

  Nothing records a view yet, so the figure is empty or sample data and is drawn with a
  `roadmap_badge/1`.
  """
  @spec untracked?(String.t()) :: boolean()
  def untracked?(label), do: label in Enum.map(@untracked_figures, &translate/1)

  @doc "Whether `title`, as a section card shows it, is a section that is on the roadmap."
  @spec on_roadmap?(String.t()) :: boolean()
  def on_roadmap?(title), do: title in Enum.map(@roadmap_sections, &translate/1)

  @doc """
  The label drawn on a figure or a section that is not working yet.

  `kind` is `:untracked` for a figure the view log feeds, `:roadmap` for a section on the roadmap.
  """
  attr :kind, :atom, required: true, values: [:untracked, :roadmap]

  def roadmap_badge(assigns) do
    ~H"""
    <span data-role="roadmap-badge" data-kind={@kind} title={roadmap_hint(@kind)} class="inline-flex">
      <Widget.badge label={roadmap_label(@kind)} tone={:amber} />
    </span>
    """
  end

  defp roadmap_label(:untracked), do: gettext("Not tracked yet")
  defp roadmap_label(:roadmap), do: gettext("On our roadmap")

  defp roadmap_hint(:untracked),
    do: gettext("Page views are not recorded yet. Counting them is on our roadmap.")

  defp roadmap_hint(:roadmap),
    do: gettext("This section is not available yet. It is on our roadmap.")

  @doc "Whether `areas` holds every blog area in `needs`."
  @spec holds?(Overview.areas(), [:post | :comment]) :: boolean()
  def holds?(areas, needs), do: Enum.all?(needs, &Map.get(areas, &1, false))

  @doc "The `+2 from yesterday` line under a day counter, worded for every sign including zero."
  @spec delta(integer(), integer()) :: String.t()
  def delta(today, today), do: gettext("Same as yesterday")

  def delta(today, yesterday) when today > yesterday,
    do: gettext("+%{difference} from yesterday", difference: Localized.number(today - yesterday))

  def delta(today, yesterday),
    do: gettext("−%{difference} from yesterday", difference: Localized.number(yesterday - today))

  @doc "The move between two windows as a percentage, or a word when there is nothing to compare to."
  @spec growth(integer(), integer()) :: String.t()
  def growth(0, 0), do: gettext("No data")
  def growth(_current, 0), do: gettext("New")

  def growth(current, previous),
    do: percent(round((current - previous) * 100 / previous), sign_display: :except_zero)

  @doc "`points` per hundred as the reader's language writes a percentage, e.g. `\"12%\"`."
  @spec percent(number(), keyword()) :: String.t()
  def percent(points, opts \\ []),
    do: Localized.number(points / 100, Keyword.put(opts, :format, :percent))

  @doc "Tone for a figure that moved: green when it rose, red when it fell, muted when it held."
  @spec move_tone(number(), number()) :: String.t()
  def move_tone(current, previous) when current > previous, do: @up
  def move_tone(current, previous) when current < previous, do: @down
  def move_tone(_current, _previous), do: @muted

  @doc "Month and year for the calendar header, e.g. `\"July 2026\"`."
  @spec month_label(Date.t()) :: String.t()
  def month_label(date), do: Localized.date(date, :yMMMM)

  @doc "Weekday, month and day for the calendar sidebar, e.g. `\"Mon, Jul 20\"`."
  @spec day_label(Date.t()) :: String.t()
  def day_label(date), do: Localized.date(date, :MMMEd)

  @doc "The calendar's column heads, Sunday first, e.g. `[\"Sun\", \"Mon\", …]`."
  @spec weekday_labels() :: [String.t()]
  def weekday_labels, do: Enum.map(0..6, &Localized.date(Date.add(@a_sunday, &1), :E))

  @doc "The calendar sidebar's count line, e.g. `\"1 post on this day\"`."
  @spec day_count_label(non_neg_integer()) :: String.t()
  def day_count_label(count),
    do: ngettext("1 post on this day", "%{count} posts on this day", count)

  @doc "The posts sitting on `date` in an already-loaded calendar."
  @spec posts_on(map() | nil, Date.t()) :: list()
  def posts_on(nil, _date), do: []

  def posts_on(%{cells: cells}, date) do
    Enum.find_value(cells, [], fn cell -> cell.date == date && cell.posts end)
  end

  @doc "Time of day a post went out, or is due to — the calendar sidebar's second line."
  @spec post_time(map()) :: String.t()
  def post_time(%{status: :scheduled, scheduled_publish_at: %DateTime{} = at}),
    do: gettext("Scheduled · %{time}", time: Localized.time(at, :Hm))

  def post_time(%{published_at: %DateTime{} = at}), do: Localized.time(at, :Hm)
  def post_time(_post), do: "—"

  @doc "Fill for one calendar square: outside the month, selected, today, or an ordinary day."
  @spec cell_tone(map(), Date.t()) :: String.t()
  def cell_tone(%{date: nil}, _selected), do: "bg-[#faf9f6]"
  def cell_tone(%{date: date}, date), do: "bg-[#f2f1fc] ring-1 ring-inset ring-[#dcdbf5]"
  def cell_tone(%{today?: true}, _selected), do: "bg-[#e6f6ee]"
  def cell_tone(_cell, _selected), do: "bg-white hover:bg-[#f7f6f3]"

  @doc "Chip colours for a post status, shared by the calendar grid and its sidebar."
  @spec status_tone(atom()) :: String.t()
  def status_tone(:published), do: "bg-[#e6f6ee] text-[#177a53]"
  def status_tone(:scheduled), do: "bg-[#eeedfb] text-[#5b57d6]"
  def status_tone(:draft), do: "bg-[#f2f1ec] text-[#6d6a63]"
  def status_tone(_status), do: "bg-[#fbf1df] text-[#a5691a]"

  @doc "The word a post status is shown as."
  @spec status_label(atom()) :: String.t()
  def status_label(:published), do: gettext("Published")
  def status_label(:scheduled), do: gettext("Scheduled")
  def status_label(:draft), do: gettext("Draft")
  def status_label(:archived), do: gettext("Archived")
  def status_label(status), do: to_string(status)

  @doc "Dot colour for a recent-activity entry, one per kind."
  @spec activity_tone(atom()) :: String.t()
  def activity_tone(:post), do: "bg-[#1f9d6b]"
  def activity_tone(:comment), do: "bg-[#3a6cb5]"
  def activity_tone(:blogger), do: "bg-[#7a5bd0]"

  @doc """
  What a recent-activity entry says happened, worded from the record's own status.

  A post is announced by the state it is actually in — the feed is ordered by creation, so the newest
  post is usually a draft, and calling that "published" would tell every admin unfinished copy went
  live.
  """
  @spec activity_label(atom(), atom() | nil) :: String.t()
  def activity_label(:post, :published), do: gettext("New post published")
  def activity_label(:post, :scheduled), do: gettext("New post scheduled")
  def activity_label(:post, :draft), do: gettext("New draft created")
  def activity_label(:post, _status), do: gettext("New post added")
  def activity_label(:comment, _status), do: gettext("New comment posted")
  def activity_label(:blogger, _status), do: gettext("New blogger joined")

  @doc """
  How long before `now` `at` was, e.g. `"3 minutes ago"` or `"yesterday"`; a moment after `now`
  reads as `"now"`.
  """
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(at, now \\ DateTime.utc_now()),
    do: Localized.ago(Enum.min([at, now], DateTime), relative_to: now)

  # THE GATE, ANSWERED ON EVERY RENDER rather than once at mount: an install, a skip or the badge all
  # change it, and each of them is an event. `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel`
  # pins the answer once an admin has said, so this follows what they said rather than re-deciding.
  defp gate(socket),
    do: assign(socket, :showing_installer?, ExtensionInstallerPanel.showing_installer?(socket))

  # A MASTER PICKS THE SITE; A TENANT ADMIN HAS ONE. The picker's options are the sites this
  # deployment has, and the one the admin is looking at — the host their request resolved to — is
  # preselected, because that is the site they mean. Read from the table rather than from
  # `SiteState`'s cache: a site created a moment ago has to be offerable at once, and the button
  # exists precisely for a site that has just appeared.
  defp assign_provision(socket, session) do
    user = socket.assigns[:current_user]
    allowed? = may_provision?(user)

    {sites, chosen} =
      cond do
        not allowed? -> {[], nil}
        is_binary(user.site_id) -> {[], user.site_id}
        true -> offered_sites(session)
      end

    assign(socket,
      may_provision?: allowed?,
      provision_sites: sites,
      provision_site_id: chosen,
      provision_site_name: (sites == [] && site_name(chosen)) || nil
    )
  end

  defp may_provision?(user),
    do: ExtensionProvision.allowed?(MishkaBlog.Provision.manifest(), user)

  # The Logs panel is the editorial resources' history, so it is a post holder's.
  defp activity_feed(socket, %{post: true}),
    do: ActivityFeed.setup(socket, resources: @blog_resources, feed_id: "blog-activity")

  defp activity_feed(socket, _areas), do: assign(socket, :activity_feed, nil)

  # WHAT TO CALL THE SITE WHEN THERE IS NO PICKER. A tenant admin is offered no list — their site
  # is the only one this page will ever write to — so the modal says which site that is instead of
  # drawing a dropdown that cannot move.
  defp site_name(site_id) when is_binary(site_id) do
    Site
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^site_id)
    |> Ash.Query.select([:name])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{name: name}} -> name
      _no_such_site -> nil
    end
  end

  defp site_name(_no_site), do: nil

  defp offered_sites(session) do
    sites =
      Site
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.select([:id, :name])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.name, &1.id})

    ids = Enum.map(sites, &elem(&1, 1))

    current =
      case session do
        %{"current_site" => %{id: id}} -> id
        _no_site_in_session -> nil
      end

    {sites, (current in ids && current) || List.first(ids)}
  end

  # NEVER THE PARAMETER ON ITS OWN. A tenant admin provisions their own site whatever the form said,
  # and a master's choice has to be one this page offered — a `site_id` typed into a socket message
  # is not an authorization to write pages to that site.
  #
  # A SITE THAT WAS NOT OFFERED IS NOT A SITE NOBODY PICKED. They are two different answers and they
  # get two different ones back: a form that submitted nothing is a form to fill in, while a site id
  # this page never listed is a refusal, and telling somebody to choose a site when they did choose
  # one reads as a bug in the page rather than as the check it is.
  defp chosen_site(%{assigns: %{current_user: %{site_id: site_id}}}, _params)
       when is_binary(site_id),
       do: site_id

  defp chosen_site(%{assigns: %{provision_sites: sites}}, params) do
    case params["site_id"] do
      asked when is_binary(asked) and asked != "" ->
        Enum.find_value(sites, :refused, fn {_name, id} -> id == asked && id end)

      _nothing_chosen ->
        :none
    end
  end

  defp load_stats(socket) do
    user = socket.assigns.current_user

    (connected?(socket) &&
       MishkaGervaz.Messages.start_async(socket, :stats, fn -> Overview.load(user) end)) || socket
  end

  defp load_calendar(%{assigns: %{calendar: calendar}} = socket) when calendar != nil, do: socket

  defp load_calendar(socket) do
    user = socket.assigns.current_user
    month = socket.assigns.month

    MishkaGervaz.Messages.start_async(socket, :calendar, fn -> Overview.calendar(user, month) end)
  end

  defp translate(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)

  defp shift_month(month, step) do
    months = month.year * 12 + month.month - 1 + step

    Date.new!(div(months, 12), rem(months, 12) + 1, 1)
  end

  defp same_day_in(month, selected) do
    Date.new!(month.year, month.month, min(selected.day, Date.days_in_month(month)))
  end

  defp views_note(0, 0), do: gettext("No views yet today")
  defp views_note(_today, 0), do: gettext("First views today")

  defp views_note(today, yesterday),
    do: gettext("%{growth} vs yesterday", growth: growth(today, yesterday))

  defp pending_note(0), do: gettext("All reviewed")
  defp pending_note(count), do: gettext("%{count} pending review", count: count)

  defp pending_tone(0), do: @body
  defp pending_tone(_count), do: @warn

  defp joined_note(0), do: gettext("None joined this month")
  defp joined_note(count), do: gettext("%{count} joined this month", count: count)

  defp points(rate, rate), do: gettext("Steady vs prev. 30d")

  defp points(rate, previous) when rate > previous,
    do: gettext("+%{points} pts vs prev. 30d", points: Localized.number(rate - previous))

  defp points(rate, previous),
    do: gettext("−%{points} pts vs prev. 30d", points: Localized.number(previous - rate))
end
