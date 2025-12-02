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

  Everything from `kpi_cards/1` down is presentation: `delta/2`, `growth/2` and `compact/1` turn raw
  counts into the labels the design shows. `MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed`
  supplies the "Logs" panel and the Calendar toggle rides in its `:toggles` slot, so both controls
  sit on one row as the design has them.

  ## What each viewer is shown

  The blog has two areas (`MishkaBlog.Dashboard.Overview.areas/1`): a holder of `admin:dashboard:blog:post` is
  shown the posts, bloggers, collections, tags, teams, auto posting and views — the calendar and the
  Logs panel included — and a holder of `admin:dashboard:blog:comment` the comments. The Engagement
  figures divide comments by views, so they need both. A card, a row or a link whose area the
  viewer does not hold is not drawn, and `MishkaBlog.Dashboard.Overview` does not read its data.

  See `MishkaBlog.Dashboard.Overview` for the queries.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Logger

  alias MishkaBlog.Dashboard.Overview
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaCmsCoreWeb.Templates.CardChrome

  @blog_resources [
    MishkaBlog.BlogPost,
    MishkaBlog.Collection,
    MishkaBlog.Team,
    MishkaBlog.Blogger,
    MishkaBlog.Tag
  ]

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
  def mount(_params, _session, socket) do
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
      {compact(stats.posts_today), delta(stats.posts_today, stats.posts_yesterday),
       move_tone(stats.posts_today, stats.posts_yesterday)}

  defp kpi("Today's Views", stats),
    do:
      {compact(stats.views_today), views_note(stats.views_today, stats.views_yesterday),
       move_tone(stats.views_today, stats.views_yesterday)}

  defp kpi("New Comments", stats),
    do:
      {compact(stats.comments_recent), pending_note(stats.comments_pending),
       pending_tone(stats.comments_pending)}

  defp kpi("Active Bloggers", stats),
    do: {compact(stats.bloggers_active), joined_note(stats.bloggers_new), @muted}

  defp kpi("Engagement", stats),
    do:
      {"#{stats.engagement_rate}%", points(stats.engagement_rate, stats.engagement_previous),
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
    do: {compact(stats.collections_total), @body, compact(stats.posts_organised), @body}

  defp section("Blog Posts", stats),
    do: {compact(stats.posts_published), @body, compact(stats.posts_drafts), @body}

  defp section("Bloggers", stats),
    do: {compact(stats.bloggers_active), @body, compact(stats.bloggers_publishers), @body}

  defp section("Teams", stats),
    do: {compact(stats.teams_active), @body, compact(stats.team_members), @body}

  defp section("Comments", stats),
    do:
      {compact(stats.comments_total), @body, compact(stats.comments_pending),
       pending_tone(stats.comments_pending)}

  defp section("Auto Posting", stats),
    do: {compact(stats.posts_scheduled), @body, compact(stats.automation_rules), @body}

  defp section("Tags", stats),
    do: {compact(stats.tags_total), @body, stats.tags_top || "—", @body}

  defp section("Analytics", stats),
    do:
      {compact(stats.views_total), @body, growth(stats.views_window, stats.views_previous),
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
  defp month("Posts Published", stats), do: {compact(stats.month_posts), @body}
  defp month("Total Views", stats), do: {compact(stats.month_views), @body}
  defp month("New Comments", stats), do: {compact(stats.month_comments), @body}
  defp month("Engagement Rate", stats), do: {"#{stats.month_engagement}%", @up}

  @doc "The Quick Actions rows `areas` may follow, as `{label, icon, path, primary?}`."
  @spec quick_actions(Overview.areas()) ::
          [{String.t(), String.t(), String.t(), boolean()}]
  def quick_actions(areas) do
    for {label, icon, path, primary?, needs} <- @quick_actions,
        holds?(areas, needs),
        do: {translate(label), icon, path, primary?}
  end

  @doc "Whether `areas` holds every blog area in `needs`."
  @spec holds?(Overview.areas(), [:post | :comment]) :: boolean()
  def holds?(areas, needs), do: Enum.all?(needs, &Map.get(areas, &1, false))

  @doc """
  Abbreviates a count the way the design writes it — 8429 becomes `8.4K`, 1_240_000 `1.2M`.

  Each tier ends just below the rounding that would carry into the next one, so 999_950 reads `1M`
  rather than `1000K`.
  """
  @spec compact(integer()) :: String.t()
  def compact(value) when value < 1_000, do: Integer.to_string(value)

  def compact(value) when value < 999_500,
    do: shorten(value, 1_000, pgettext("thousands abbreviation", "K"))

  def compact(value) when value < 999_500_000,
    do: shorten(value, 1_000_000, pgettext("millions abbreviation", "M"))

  def compact(value), do: shorten(value, 1_000_000_000, pgettext("billions abbreviation", "B"))

  @doc "The `+2 from yesterday` line under a day counter, worded for every sign including zero."
  @spec delta(integer(), integer()) :: String.t()
  def delta(today, today), do: gettext("Same as yesterday")

  def delta(today, yesterday) when today > yesterday,
    do: gettext("+%{difference} from yesterday", difference: today - yesterday)

  def delta(today, yesterday),
    do: gettext("−%{difference} from yesterday", difference: yesterday - today)

  @doc "The move between two windows as a percentage, or a word when there is nothing to compare to."
  @spec growth(integer(), integer()) :: String.t()
  def growth(0, 0), do: gettext("No data")
  def growth(_current, 0), do: gettext("New")
  def growth(current, previous), do: percentage(round((current - previous) * 100 / previous))

  @doc "Tone for a figure that moved: green when it rose, red when it fell, muted when it held."
  @spec move_tone(number(), number()) :: String.t()
  def move_tone(current, previous) when current > previous, do: @up
  def move_tone(current, previous) when current < previous, do: @down
  def move_tone(_current, _previous), do: @muted

  @doc "Long month and year for the calendar header, e.g. `\"July 2026\"`."
  @spec month_label(Date.t()) :: String.t()
  def month_label(date), do: strftime(date, "%B %Y")

  @doc "Weekday with short month and day for the calendar sidebar, e.g. `\"Monday, Jul 20\"`."
  @spec day_label(Date.t()) :: String.t()
  def day_label(date), do: strftime(date, "%A, %b %-d")

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
    do: gettext("Scheduled · %{time}", time: Calendar.strftime(at, "%H:%M"))

  def post_time(%{published_at: %DateTime{} = at}), do: Calendar.strftime(at, "%H:%M")
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

  @doc "How long ago something happened, to the coarsest unit that still says something."
  @spec ago(DateTime.t()) :: String.t()
  def ago(at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> gettext("just now")
      seconds < 3_600 -> minutes_ago(div(seconds, 60))
      seconds < 86_400 -> hours_ago(div(seconds, 3_600))
      seconds < 2_592_000 -> days_ago(div(seconds, 86_400))
      true -> strftime(at, "%b %d, %Y")
    end
  end

  @doc """
  `Calendar.strftime/3` with the month and weekday names spelled in the language of the process that
  renders, for a date or datetime shown on a screen.
  """
  @spec strftime(Calendar.date() | Calendar.datetime(), String.t()) :: String.t()
  def strftime(date, format) do
    Calendar.strftime(date, format,
      day_of_week_names: &day_name/1,
      abbreviated_day_of_week_names: &short_day_name/1,
      month_names: &month_name/1,
      abbreviated_month_names: &short_month_name/1
    )
  end

  # The Logs panel is the editorial resources' history, so it is a post holder's.
  defp activity_feed(socket, %{post: true}),
    do: ActivityFeed.setup(socket, resources: @blog_resources, feed_id: "blog-activity")

  defp activity_feed(socket, _areas), do: assign(socket, :activity_feed, nil)

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

  defp minutes_ago(count), do: ngettext("1 minute ago", "%{count} minutes ago", count)
  defp hours_ago(count), do: ngettext("1 hour ago", "%{count} hours ago", count)
  defp days_ago(count), do: ngettext("1 day ago", "%{count} days ago", count)

  defp translate(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)

  defp day_name(1), do: gettext("Monday")
  defp day_name(2), do: gettext("Tuesday")
  defp day_name(3), do: gettext("Wednesday")
  defp day_name(4), do: gettext("Thursday")
  defp day_name(5), do: gettext("Friday")
  defp day_name(6), do: gettext("Saturday")
  defp day_name(7), do: gettext("Sunday")

  defp short_day_name(1), do: gettext("Mon")
  defp short_day_name(2), do: gettext("Tue")
  defp short_day_name(3), do: gettext("Wed")
  defp short_day_name(4), do: gettext("Thu")
  defp short_day_name(5), do: gettext("Fri")
  defp short_day_name(6), do: gettext("Sat")
  defp short_day_name(7), do: gettext("Sun")

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")

  defp short_month_name(1), do: gettext("Jan")
  defp short_month_name(2), do: gettext("Feb")
  defp short_month_name(3), do: gettext("Mar")
  defp short_month_name(4), do: gettext("Apr")
  defp short_month_name(5), do: gettext("May")
  defp short_month_name(6), do: gettext("Jun")
  defp short_month_name(7), do: gettext("Jul")
  defp short_month_name(8), do: gettext("Aug")
  defp short_month_name(9), do: gettext("Sep")
  defp short_month_name(10), do: gettext("Oct")
  defp short_month_name(11), do: gettext("Nov")
  defp short_month_name(12), do: gettext("Dec")

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
    do: gettext("+%{points} pts vs prev. 30d", points: rate - previous)

  defp points(rate, previous),
    do: gettext("−%{points} pts vs prev. 30d", points: previous - rate)

  defp percentage(points) when points > 0, do: "+#{points}%"
  defp percentage(points), do: "#{points}%"

  defp shorten(value, unit, suffix) do
    tenths = round(value / (unit / 10))

    case {div(tenths, 10), rem(tenths, 10)} do
      {whole, 0} -> "#{whole}#{suffix}"
      {whole, part} -> "#{whole}.#{part}#{suffix}"
    end
  end
end
