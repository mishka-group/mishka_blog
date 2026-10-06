defmodule MishkaBlog.Dashboard.Widgets.CommentsModeration do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): comments awaiting moderation — a pending count
  plus the latest few with an excerpt of their content (`Comment` `:master_read`, filtered to
  `:pending`). A master moderates across every site; a tenant admin only their own site's.

  How many comments the queue lists is the viewer's own setting — the card's gear in customize mode,
  or Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the four status tiles always count the whole
  queue.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 100}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaCmsCore.Dashboard.Widget

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Comments to show"),
    default: 3,
    min: 1,
    max: 10
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "blog-comments-moderation",
        priority: 100,
        pubsub: [MishkaBlog.Comment],
        title: gettext_noop("Comments to moderate"),
        component: {__MODULE__, :render},
        permission: "admin:dashboard:blog:comment",
        size: 2,
        icon: "hero-chat-bubble-left-right",
        link: "/admin/dashboard/blog/comments",
        settings_category: "blog",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer, listing as
  many comments as their own "Comments to show" setting asks for. Called as `load/1` (a direct call,
  no dashboard) it uses the declared default.
  """
  def load(user, config \\ %{}) do
    scope = Widget.scope(user)

    base =
      MishkaBlog.Comment
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> scope_filter(scope)

    counts = %{
      pending: count_status(base, :pending),
      flagged: count_status(base, :flagged),
      spam: count_status(base, :spam),
      approved: count_status(base, :approved)
    }

    %{results: latest} =
      base
      |> Ash.Query.load([:author_profile, :author_master? | authors_seen_by(scope)])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(page: [limit: Map.get(config, @count.key, @count.default)], authorize?: false)

    %{counts: counts, latest: latest}
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header
      icon="hero-chat-bubble-left-right"
      tone={:gray}
      title={gettext("Comments to moderate")}
    />
    <div class="mb-3.5 grid grid-cols-2 gap-2">
      <.tile
        label={gettext("Pending")}
        value={@data.counts.pending}
        bg="bg-[#fbf1df]"
        fg="text-[#a5691a]"
        num="text-[#a5691a]"
        dot="bg-[#cf8a24]"
      />
      <.tile
        label={gettext("Flagged")}
        value={@data.counts.flagged}
        bg="bg-[#fbe9e7]"
        fg="text-[#b3433a]"
        num="text-[#b3433a]"
        dot="bg-[#d5544b]"
      />
      <.tile
        label={gettext("Spam")}
        value={@data.counts.spam}
        bg="bg-[#f2f1ec]"
        fg="text-[#6d6a63]"
        num="text-[#4a483f]"
        dot="bg-[#8a877f]"
      />
      <.tile
        label={gettext("Approved")}
        value={@data.counts.approved}
        bg="bg-[#e6f6ee]"
        fg="text-[#177a53]"
        num="text-[#177a53]"
        dot="bg-[#1f9d6b]"
      />
    </div>
    <div :for={c <- @data.latest} class="border-t border-[#f4f3ef] py-2.5">
      <div class="mb-1 flex items-center gap-2">
        <Widget.badge label={status_label(c.status)} tone={status_tone(c.status)} />
        <span class="truncate text-[11.5px] font-semibold text-[#3a382f]">{MishkaBlogWeb.Templates.CommentCard.author(
          c
        )}</span>
        <span class="flex-1"></span>
        <span class="shrink-0 text-[11px] font-medium text-[#a8a5a0]">
          {Widget.relative_time(c.inserted_at)}
        </span>
      </div>
      <div class="line-clamp-2 text-[12px] font-medium text-[#7c7a75]">{c.content}</div>
    </div>
    <Widget.empty
      :if={@data.latest == []}
      icon="hero-chat-bubble-left-right"
      message={gettext("Nothing to moderate.")}
    />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} border={false} />
    """
  end

  defp tile(assigns) do
    ~H"""
    <div class={["rounded-[11px] px-3 py-2.5", @bg]}>
      <div class={["flex items-center gap-1.5 text-[10.5px] font-semibold", @fg]}>
        <span class={["size-1.5 shrink-0 rounded-full", @dot]} />{@label}
      </div>
      <div class={["mt-[3px] font-['Space_Grotesk'] text-[20px] font-semibold", @num]}>{@value}</div>
    </div>
    """
  end

  defp status_label(:pending), do: gettext("pending")
  defp status_label(:flagged), do: gettext("flagged")
  defp status_label(:spam), do: gettext("spam")
  defp status_label(:approved), do: gettext("approved")
  defp status_label(status), do: to_string(status)

  defp status_tone(:pending), do: :amber
  defp status_tone(:flagged), do: :red
  defp status_tone(:approved), do: :green
  defp status_tone(_), do: :gray

  # A master reads every account; a site's admin only its own site's, so a master writing on a site
  # is named there by its blogger profile on that site, or as a master, never by its account.
  defp authors_seen_by(nil), do: [:author]

  defp authors_seen_by(site_id),
    do: [author: Ash.Query.filter(MishkaCmsCore.Accounts.User, site_id == ^site_id)]

  defp count_status(base, value),
    do: base |> Ash.Query.filter(status == ^value) |> Ash.count!(authorize?: false)

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)
end
