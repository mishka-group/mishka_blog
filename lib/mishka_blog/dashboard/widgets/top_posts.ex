# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Widgets.TopPosts do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the most-viewed published posts with their view
  tally (`BlogPost` + the `view_count` aggregate), read as the viewer through
  `MishkaBlog.Dashboard.Scope`: a master ranks posts across every site, a site's admin only their
  own site's, and a viewer without `admin:dashboard:blog:post` none.

  How many posts the leaderboard ranks is the viewer's own setting — the card's gear in customize
  mode, or Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`).
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 60}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaBlog.Dashboard.Scope
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Posts to rank"),
    default: 5,
    min: 3,
    max: 12
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "blog-top-posts",
        priority: 60,
        pubsub: [MishkaBlog.BlogPost],
        title: gettext_noop("Top posts"),
        component: {__MODULE__, :render},
        size: 2,
        permission: "admin:dashboard:blog:post",
        icon: "hero-fire",
        link: "/admin/dashboard/blog/analytics",
        settings_category: "blog",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), read as the viewer and sized by
  their own "Posts to rank" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    posts =
      MishkaBlog.BlogPost
      |> Scope.query(user)
      |> Ash.Query.filter(status == :published)
      |> Ash.Query.load([:view_count])
      |> Ash.Query.sort(view_count: :desc)
      |> Scope.list(Map.get(config, @count.key, @count.default))

    %{posts: posts}
  end

  def render(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.data.posts))

    ~H"""
    <Widget.card_header
      icon="hero-arrow-trending-up"
      tone={:violet}
      title={gettext("Top posts")}
      subtitle={gettext("Most viewed this month")}
    >
      <:right>
        <span
          data-role="roadmap-badge"
          title={gettext("Page views are not recorded yet. Counting them is on our roadmap.")}
        >
          <Widget.pill label={gettext("Not tracked yet")} tone={:amber} />
        </span>
      </:right>
    </Widget.card_header>
    <div :if={@rows != []}>
      <div
        :for={r <- @rows}
        class="relative mb-2 h-[42px] overflow-hidden rounded-[11px] bg-[#faf9f6]"
      >
        <div class="absolute inset-y-0 start-0" style={"width:#{r.pct}%;background:#{r.fill};"} />
        <div class="relative flex h-full items-center gap-2.5 px-3">
          <span class={[
            "grid size-[22px] shrink-0 place-items-center rounded-[7px] font-['Space_Grotesk'] text-[11px] font-bold",
            r.chip
          ]}>
            {r.rank}
          </span>
          <span class="min-w-0 flex-1 truncate text-[12.5px] font-semibold text-[#1b1a18]">
            {r.title}
          </span>
          <span class="inline-flex shrink-0 items-center gap-1 font-['Space_Grotesk'] text-[11.5px] font-bold text-[#3a382f]">
            <span class="hero-eye size-3 text-[#8a877f]" />{r.views}
          </span>
        </div>
      </div>
    </div>
    <Widget.empty :if={@rows == []} icon="hero-fire" message={gettext("No published posts yet.")} />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} />
    """
  end

  defp rows(posts) do
    max = posts |> Enum.map(& &1.view_count) |> Enum.max(fn -> 0 end)

    posts
    |> Enum.with_index(1)
    |> Enum.map(fn {post, rank} ->
      %{
        rank: rank,
        title: post.title,
        views: Localized.compact(post.view_count),
        pct: pct(post.view_count, max),
        fill: fill(rank),
        chip: chip(rank)
      }
    end)
  end

  defp pct(_views, 0), do: 0
  defp pct(views, max), do: round(views / max * 100)

  defp fill(1), do: "#d9d6f6"
  defp fill(2), do: "#e4e2f9"
  defp fill(3), do: "#eae8fb"
  defp fill(4), do: "#f0eff8"
  defp fill(_), do: "#f4f3f8"

  defp chip(1), do: "bg-[#5b57d6] text-white"
  defp chip(r) when r in [2, 3], do: "bg-[#eeedfb] text-[#5b57d6]"
  defp chip(_), do: "bg-[#f2f1ec] text-[#8a877f]"
end
