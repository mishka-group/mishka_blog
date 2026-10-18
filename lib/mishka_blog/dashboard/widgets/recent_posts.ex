# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Widgets.RecentPosts do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the latest blog posts with their status, read as
  the viewer through `MishkaBlog.Dashboard.Scope`: a master sees every site's posts, a site's admin
  only their own site's, and a viewer without `admin:dashboard:blog:post` none.

  How many posts it reads is the viewer's own setting — the card's gear in customize mode, or
  Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`). The count is how many posts you see: the featured
  one leads the card and the remainder are listed beneath it.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaBlog.Dashboard.Scope
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Posts to show"),
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
        id: "blog-recent-posts",
        priority: 50,
        pubsub: [MishkaBlog.BlogPost],
        title: gettext_noop("Recent posts"),
        component: {__MODULE__, :render},
        size: 2,
        permission: "admin:dashboard:blog:post",
        icon: "hero-newspaper",
        link: "/admin/dashboard/blog/posts",
        settings_category: "blog",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), read as the viewer and sized by
  their own "Posts to show" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    count = Map.get(config, @count.key, @count.default)

    posts =
      MishkaBlog.BlogPost
      |> Scope.query(user)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.select([:id, :title, :excerpt, :status, :featured, :reading_time_minutes])
      |> Ash.Query.load([:view_count, :comment_count, authors(Widget.scope(user))])
      |> Scope.list(count)

    %{posts: posts, count: count}
  end

  def render(assigns) do
    posts = assigns.data.posts
    featured = Enum.find(posts, & &1.featured) || List.first(posts)
    rows = Map.get(assigns.data, :count, @count.default) - 1

    more =
      if featured,
        do: posts |> Enum.reject(&(&1.id == featured.id)) |> Enum.take(rows),
        else: []

    assigns = assign(assigns, featured: featured, more: more, author: author_name(featured))

    ~H"""
    <Widget.card_header icon="hero-newspaper" tone={:gray} title={gettext("Recent posts")} />
    <%= if @featured do %>
      <div class="mb-3.5 overflow-hidden rounded-[14px] border border-[#f0efea]">
        <div class="relative h-[88px] bg-[repeating-linear-gradient(135deg,#efe9fb,#efe9fb_8px,#e7e0f7_8px,#e7e0f7_16px)]">
          <span
            :if={@featured.featured}
            class="absolute start-2.5 top-2.5 inline-flex items-center gap-[3px] rounded-[7px] bg-white px-2 py-1 text-[8.5px] font-bold tracking-[0.05em] text-[#a5691a] shadow-[0_2px_6px_rgba(30,28,24,0.12)]"
          >
            <span class="hero-star-solid size-[9px] text-[#cf8a24]" />{gettext("FEATURED")}
          </span>
          <span class="absolute end-2.5 top-2.5">
            <Widget.badge label={status_label(@featured.status)} tone={status_tone(@featured.status)} />
          </span>
        </div>
        <div class="p-[13px]">
          <div class="truncate text-[13.5px] font-bold text-[#17161a]">{@featured.title}</div>
          <div class="mt-1 line-clamp-2 text-[11.5px] font-medium text-[#8a877f]">
            {@featured.excerpt}
          </div>
          <div class="mt-[11px] flex items-center gap-[9px]">
            <span :if={@author} class="text-[11px] font-semibold text-[#5c5a54]">{@author}</span>
            <span :if={@author} class="size-[3px] rounded-full bg-[#d5d2c9]" />
            <span class="text-[11px] font-medium text-[#a8a5a0]">
              {gettext("%{minutes} min", minutes: @featured.reading_time_minutes)}
            </span>
            <span class="flex-1"></span>
            <span
              data-role="roadmap-hint"
              title={views_hint()}
              class="inline-flex items-center gap-1 text-[11px] font-semibold text-[#8a877f]"
            >
              <span class="hero-eye size-3 text-[#a8a5a0]" />{fmt_count(@featured.view_count)}
            </span>
            <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-[#8a877f]">
              <span class="hero-chat-bubble-left size-3 text-[#a8a5a0]" />{@featured.comment_count}
            </span>
          </div>
        </div>
      </div>
      <div
        :for={p <- @more}
        class="flex items-center gap-2.5 border-t border-[#f4f3ef] py-[9px]"
      >
        <Widget.badge label={status_label(p.status)} tone={status_tone(p.status)} />
        <span class="min-w-0 flex-1 truncate text-xs font-semibold text-[#1b1a18]">{p.title}</span>
        <span
          data-role="roadmap-hint"
          title={views_hint()}
          class="inline-flex shrink-0 items-center gap-1 text-[10.5px] font-semibold text-[#a8a5a0]"
        >
          <span class="hero-eye size-[11px] text-[#bcb9b2]" />{fmt_count(p.view_count)}
        </span>
      </div>
      <Widget.card_footer link={@widget.link} label={gettext("View all posts")} />
    <% else %>
      <Widget.empty icon="hero-newspaper" message={gettext("No posts yet.")} />
    <% end %>
    """
  end

  defp views_hint,
    do: gettext("Page views are not recorded yet. Counting them is on our roadmap.")

  # A master reads a post's bloggers through the bloggers' master read, a site's admin through
  # their tenant read.
  defp authors(nil), do: :master_bloggers
  defp authors(_site_id), do: :tenant_bloggers

  defp status_label(:draft), do: gettext("draft")
  defp status_label(:published), do: gettext("published")
  defp status_label(:scheduled), do: gettext("scheduled")
  defp status_label(:archived), do: gettext("archived")
  defp status_label(status), do: to_string(status)

  defp status_tone(:published), do: :green
  defp status_tone(:scheduled), do: :violet
  defp status_tone(:archived), do: :amber
  defp status_tone(_status), do: :gray

  defp author_name(%{master_bloggers: [%{display_name: name} | _]}) when is_binary(name), do: name
  defp author_name(%{tenant_bloggers: [%{display_name: name} | _]}) when is_binary(name), do: name
  defp author_name(_post), do: nil

  defp fmt_count(n) when is_integer(n), do: Localized.compact(n)
  defp fmt_count(_n), do: Localized.compact(0)
end
