# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Widgets.DraftsScheduled do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): draft vs scheduled post counts plus the latest
  unpublished posts — drafts with their age, scheduled posts with their publish time (`BlogPost`
  `:master_read`). A master sees every site's pipeline; a tenant admin only their own site's.

  How many posts the list holds is the viewer's own setting — the card's gear in customize mode, or
  Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the two counters above it always count the whole
  pipeline.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 80}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

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
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer and sized by
  their own "Posts to list" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    scope = Widget.scope(user)

    %{results: latest} =
      MishkaBlog.BlogPost
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> scope_filter(scope)
      |> Ash.Query.filter(status in [:draft, :scheduled])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(page: [limit: Map.get(config, @count.key, @count.default)], authorize?: false)

    %{
      drafts: count_status(scope, :draft),
      scheduled: count_status(scope, :scheduled),
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

  defp count_status(scope, value) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> scope_filter(scope)
    |> Ash.Query.filter(status == ^value)
    |> Ash.count!(authorize?: false)
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp time_label(%{status: :scheduled, scheduled_publish_at: %DateTime{} = at}),
    do: MishkaCmsCore.Localized.datetime(at, :MMMdHm)

  defp time_label(post), do: Widget.relative_time(post.inserted_at)
end
