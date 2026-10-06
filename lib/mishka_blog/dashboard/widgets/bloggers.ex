defmodule MishkaBlog.Dashboard.Widgets.Bloggers do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the top bloggers leaderboard — a podium of the
  three most-published profiles plus the runners-up, each with their post tally and publish role
  (`Blogger` `:master_read` + the `post_count` aggregate). A master ranks bloggers across every
  site; a tenant admin only their own site's.

  How many bloggers the leaderboard ranks is the viewer's own setting — the card's gear in customize
  mode, or Settings → Blog → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`). The first three always fill the podium, so the
  setting starts at three and everything past it becomes a runner-up row.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 70}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaCmsCore.Dashboard.Widget

  @palette ~w(#5b57d6 #1f9d6b #cf8a24 #3b6fd4 #8a877f)

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Bloggers to rank"),
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
        id: "blog-bloggers",
        priority: 70,
        pubsub: [MishkaBlog.Blogger, MishkaBlog.BlogPost],
        title: gettext_noop("Bloggers"),
        component: {__MODULE__, :render},
        permission: "admin:dashboard:blog:post",
        icon: "hero-user-group",
        size: 2,
        link: "/admin/dashboard/blog/bloggers",
        settings_category: "blog",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer and sized by
  their own "Bloggers to rank" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    base =
      MishkaBlog.Blogger
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> scope_filter(Widget.scope(user))

    %{results: top} =
      base
      |> Ash.Query.load(:post_count)
      |> Ash.Query.sort(post_count: :desc, inserted_at: :desc)
      |> Ash.read!(page: [limit: Map.get(config, @count.key, @count.default)], authorize?: false)

    active =
      base
      |> Ash.Query.filter(inserted_at >= ^month_start())
      |> Ash.count!(authorize?: false)

    %{active_this_month: active, bloggers: top}
  end

  def render(assigns) do
    bloggers = assigns.data.bloggers

    assigns =
      assign(assigns,
        first: Enum.at(bloggers, 0),
        second: Enum.at(bloggers, 1),
        third: Enum.at(bloggers, 2),
        rest: Enum.drop(bloggers, 3)
      )

    ~H"""
    <Widget.card_header
      icon="hero-star"
      tone={:gray}
      title={gettext("Top bloggers")}
      subtitle={gettext("%{count} active this month", count: @data.active_this_month)}
    />
    <%= if @data.bloggers == [] do %>
      <Widget.empty icon="hero-user-group" message={gettext("No bloggers yet.")} />
    <% else %>
      <div class="mb-2 grid grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)_minmax(0,1fr)] items-end gap-2">
        <div :if={@second} class="flex flex-col items-center text-center">
          <div class="relative mb-[5px]">
            <span
              class="flex size-11 items-center justify-center rounded-[13px] font-['Space_Grotesk'] text-[14px] font-bold text-white shadow-[0_3px_8px_rgba(30,28,24,0.12)]"
              style={"background:#{avatar_color(1)}"}
            >
              {initials(@second.display_name)}
            </span>
            <span class="absolute -bottom-[7px] left-1/2 flex size-[19px] -translate-x-1/2 items-center justify-center rounded-full border-2 border-white bg-[#eef0f2] font-['Space_Grotesk'] text-[9px] font-bold text-[#8b9096]">
              2
            </span>
          </div>
          <div class="mt-[5px] max-w-full truncate text-[11.5px] font-bold text-[#1b1a18]">
            {first_name(@second.display_name)}
          </div>
          <div class="mt-px font-['Space_Grotesk'] text-[12px] font-semibold text-[#5c5a54]">
            {@second.post_count}
            <span class="font-['Manrope'] text-[9px] font-medium text-[#a8a5a0]">{gettext("posts")}</span>
          </div>
          <div class="mt-[9px] h-7 w-full rounded-t-[9px] bg-gradient-to-b from-[#f3f4f5] to-[#eceeef]" />
        </div>

        <div :if={@first} class="flex flex-col items-center text-center">
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="#d9a441"
            stroke="none"
            class="mb-0.5"
          >
            <path d="M3 8l4.5 3L12 4l4.5 7L21 8l-1.6 10.5a1 1 0 0 1-1 .5H5.6a1 1 0 0 1-1-.5z" />
          </svg>
          <div class="relative mb-[5px]">
            <span
              class="flex size-[52px] items-center justify-center rounded-[15px] font-['Space_Grotesk'] text-[16px] font-bold text-white shadow-[0_5px_14px_rgba(79,75,204,0.28)]"
              style={"background:#{avatar_color(0)}"}
            >
              {initials(@first.display_name)}
            </span>
            <span class="absolute -bottom-[7px] left-1/2 flex size-[21px] -translate-x-1/2 items-center justify-center rounded-full border-2 border-white bg-[#fbf1df] font-['Space_Grotesk'] text-[10px] font-bold text-[#c8971f]">
              1
            </span>
          </div>
          <div class="mt-1.5 max-w-full truncate text-[12.5px] font-bold text-[#17161a]">
            {first_name(@first.display_name)}
          </div>
          <div class="mt-px font-['Space_Grotesk'] text-[13px] font-semibold text-[#3a382f]">
            {@first.post_count}
            <span class="font-['Manrope'] text-[9px] font-medium text-[#a8a5a0]">{gettext("posts")}</span>
          </div>
          <div class="mt-[9px] h-11 w-full rounded-t-[9px] bg-gradient-to-b from-[#efedfc] to-[#e3e0f8]" />
        </div>

        <div :if={@third} class="flex flex-col items-center text-center">
          <div class="relative mb-[5px]">
            <span
              class="flex size-11 items-center justify-center rounded-[13px] font-['Space_Grotesk'] text-[14px] font-bold text-white shadow-[0_3px_8px_rgba(30,28,24,0.12)]"
              style={"background:#{avatar_color(2)}"}
            >
              {initials(@third.display_name)}
            </span>
            <span class="absolute -bottom-[7px] left-1/2 flex size-[19px] -translate-x-1/2 items-center justify-center rounded-full border-2 border-white bg-[#f6ece2] font-['Space_Grotesk'] text-[9px] font-bold text-[#b3794e]">
              3
            </span>
          </div>
          <div class="mt-[5px] max-w-full truncate text-[11.5px] font-bold text-[#1b1a18]">
            {first_name(@third.display_name)}
          </div>
          <div class="mt-px font-['Space_Grotesk'] text-[12px] font-semibold text-[#5c5a54]">
            {@third.post_count}
            <span class="font-['Manrope'] text-[9px] font-medium text-[#a8a5a0]">{gettext("posts")}</span>
          </div>
          <div class="mt-[9px] h-5 w-full rounded-t-[9px] bg-gradient-to-b from-[#f7f0ea] to-[#f1e6dc]" />
        </div>
      </div>

      <div
        :for={{b, i} <- Enum.with_index(@rest)}
        class="flex items-center gap-[11px] border-t border-[#f4f3ef] py-[9px]"
      >
        <span class="w-5 flex-none text-center font-['Space_Grotesk'] text-[11px] font-bold text-[#bcb9b2]">
          {i + 4}
        </span>
        <span
          class="flex size-[30px] flex-none items-center justify-center rounded-[9px] font-['Space_Grotesk'] text-[11px] font-bold text-white"
          style={"background:#{avatar_color(i + 3)}"}
        >
          {initials(b.display_name)}
        </span>
        <div class="min-w-0 flex-1">
          <div class="truncate text-[12.5px] font-semibold text-[#1b1a18]">{b.display_name}</div>
          <div class="text-[10.5px] font-medium text-[#a8a5a0]">{role(b.can_publish_directly)}</div>
        </div>
        <span class="inline-flex flex-none items-baseline gap-[3px] rounded-[20px] bg-[#f6f5f2] px-[9px] py-1">
          <span class="font-['Space_Grotesk'] text-[12px] font-bold text-[#3a382f]">
            {b.post_count}
          </span>
          <span class="text-[10px] font-medium text-[#a8a5a0]">{gettext("posts")}</span>
        </span>
      </div>

      <Widget.card_footer link={@widget.link} label={gettext("View all")} />
    <% end %>
    """
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp first_name(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> Kernel.||(name)
  end

  defp avatar_color(i), do: Enum.at(@palette, rem(i, length(@palette)))

  defp role(true), do: gettext("Publisher")
  defp role(_), do: gettext("Contributor")

  defp month_start do
    today = Date.utc_today()
    DateTime.new!(Date.new!(today.year, today.month, 1), ~T[00:00:00])
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)
end
