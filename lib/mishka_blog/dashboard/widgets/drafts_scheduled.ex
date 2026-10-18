# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Widgets.DraftsScheduled do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): draft vs scheduled post counts plus the latest
  unpublished posts — drafts with their age, scheduled posts with their publish time (`BlogPost`),
  read as the viewer through `MishkaBlog.Dashboard.Scope`: a master sees every site's pipeline, a
  site's admin only their own site's, and a viewer without `admin:dashboard:blog:post` none.

  How many posts the list holds is the viewer's own setting — the card's gear in customize mode, or
  Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the two counters above it always count the whole
  pipeline.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 80}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaBlog.Dashboard.Scope
  alias MishkaCmsCore.Dashboard.Widget

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Posts to list"),
    default: 4,
    min: 1,
    max: 12
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "blog-drafts-scheduled",
        priority: 80,
        pubsub: [MishkaBlog.BlogPost],
        title: gettext_noop("Drafts & scheduled"),
        component: {__MODULE__, :render},
        size: 2,
        permission: "admin:dashboard:blog:post",
        icon: "hero-pencil",
        link: "/admin/dashboard/blog/posts",
        settings_category: "blog",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), read as the viewer and sized by
  their own "Posts to list" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    base = Scope.query(MishkaBlog.BlogPost, user)

    latest =
      base
      |> Ash.Query.filter(status in [:draft, :scheduled])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Scope.list(Map.get(config, @count.key, @count.default))

    %{
      drafts: count_status(base, :draft),
      scheduled: count_status(base, :scheduled),
      latest: latest
    }
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-pencil" tone={:gray} title={gettext("Drafts & scheduled")} />
    <div class="mb-3.5 flex gap-2.5">
      <div class="flex-1">
        <div class="font-['Space_Grotesk'] text-[30px] font-semibold tracking-[-0.03em] text-[#17161a]">
          {@data.drafts}
        </div>
        <div class="mt-0.5 text-[11.5px] font-medium text-[#8a877f]">{gettext("Drafts")}</div>
      </div>
      <div class="flex-1 border-s border-[#f0efea] ps-3.5">
        <div class="font-['Space_Grotesk'] text-[30px] font-semibold tracking-[-0.03em] text-[#17161a]">
          {@data.scheduled}
        </div>
        <div class="mt-0.5 text-[11.5px] font-medium text-[#8a877f]">{gettext("Scheduled")}</div>
      </div>
    </div>
    <p
      :if={@data.scheduled > 0}
      data-role="roadmap-hint"
      class="mb-3.5 text-[11.5px] font-medium text-[#a5691a]"
    >
      {gettext("Publishing at the scheduled time is on our roadmap.")}
    </p>
    <div
      :for={p <- @data.latest}
      class="flex items-center gap-[9px] border-t border-[#f4f3ef] py-2"
    >
      <span class="size-1.5 shrink-0 rounded-full bg-[#cf8a24]" />
      <span class="min-w-0 flex-1 truncate text-xs font-medium text-[#3a382f]">{p.title}</span>
      <span class="shrink-0 text-[11px] font-medium text-[#a8a5a0]">{time_label(p)}</span>
    </div>
    <Widget.empty
      :if={@data.latest == []}
      icon="hero-pencil"
      message={gettext("No drafts or scheduled posts.")}
    />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} />
    """
  end

  defp count_status(base, value),
    do: base |> Ash.Query.filter(status == ^value) |> Scope.count()

  defp time_label(%{status: :scheduled, scheduled_publish_at: %DateTime{} = at}),
    do: MishkaCmsCore.Localized.datetime(at, :MMMdHm)

  defp time_label(post), do: Widget.relative_time(post.inserted_at)
end
