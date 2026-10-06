defmodule MishkaBlogWeb.Templates.TeamCard do
  @moduledoc """
  The teams grid: one card per editorial team, as many to a row as the viewport can hold.

  Declared only by `MishkaBlog.Team`, and it reads that record directly rather than by column
  position. Same shape as `MishkaBlogWeb.Templates.BloggerCard` — a tile beside its actions, a name
  over its size, the members' faces, and a footer of real counts — because a team and a blogger are
  read the same way.

  ## No fabricated engagement

  The prototype's card ends in an "Engagement 86%" bar, invented for every team; `MishkaBlog.Team`
  has no engagement metric. The footer shows the two figures that are real — `member_count` and
  `follower_count` — and the card carries the team's real `status` (active / inactive / draft) as a
  badge, which is the axis the Status filter turns on.

  ## Features
  - `:filter` - the labelled filter row: search, site, status
  - `:select` - per-card selection for bulk operations
  - `:bulk_actions` - bulk actions on the selected cards
  - `:paginate` - the page-size picker and Load more under the grid

  The furniture is `MishkaCmsCoreWeb.Templates.CardChrome` and the controls are
  `MishkaCmsCoreWeb.UIAdapters.Admin`, both shared with every other blog card page.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  @statuses %{
    active: %{
      label: dgettext_noop("mishka_gervaz", "Active"),
      chip: "bg-[#e6f6ee] text-[#177a53]"
    },
    inactive: %{
      label: dgettext_noop("mishka_gervaz", "Inactive"),
      chip: "bg-[#f2f1ec] text-[#6d6a63]"
    },
    draft: %{label: dgettext_noop("mishka_gervaz", "Draft"), chip: "bg-[#fbf1df] text-[#a5691a]"}
  }

  # The overlapping member faces cycle these tints by position so neighbours never share one.
  @member_tints [
    "bg-[#eef1fc] text-[#4f4bcc]",
    "bg-[#eaf6ee] text-[#177a53]",
    "bg-[#fbf1df] text-[#a5691a]",
    "bg-[#f4ecfb] text-[#8a4bcc]",
    "bg-[#e6f5f2] text-[#1f8f86]"
  ]

  @members_shown 5

  @impl true
  def name, do: :card_grid

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc "The switcher draws the grid-of-squares glyph, identical to every other blog card page."
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Card grid for teams")

  @impl true
  def features do
    [:filter, :select, :bulk_actions, :paginate]
  end

  @impl true
  def default_options, do: []

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:before_table, fn -> nil end)
      |> Gervaz.assign_card_flags()

    ~H"""
    <div class="mishka-gervaz-team-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="grid items-start gap-4 grid-cols-[repeat(auto-fill,minmax(min(100%,300px),1fr))]"
        data_role="tm-grid"
        empty_label={dgettext("mishka_gervaz", "0 teams")}
        empty_icon="hero-user-group"
        empty_class="col-span-full"
        show_checkboxes={@show_checkboxes}
        show_filters={@show_filters}
        show_pagination={@show_pagination}
        show_bulk_actions={@show_bulk_actions}
        show_switcher={@show_switcher}
        before_table={@before_table}
      >
        <:records>
          <.render_item
            :for={{id, record} <- @stream}
            id={id}
            record={record}
            static={@static}
            state={@state}
            show_checkboxes={@show_checkboxes}
            myself={@myself}
          />
        </:records>
      </Shared.card_scaffold>
    </div>
    """
  end

  @doc "One team card."
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    members = members(record)

    assigns =
      assigns
      |> assign(:checked?, checked?)
      |> assign(:row_class, Gervaz.custom_row_class(assigns.static, record))
      |> assign(:status, status_badge(record))
      |> assign(:members_count, count(record, :member_count))
      |> assign(:followers, count(record, :follower_count))
      |> assign(:members_shown, Enum.take(members, @members_shown))
      |> assign(:members_rest, length(members) - @members_shown)
      |> assign(:site, site_name(record, state))
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="tmcard"
      class={[
        "flex flex-col rounded-2xl border bg-white p-[18px] shadow-[0_1px_2px_rgba(30,28,24,0.04)]",
        (@checked? && "border-[#dcdbf5] ring-2 ring-[#5b57d6]") || "border-[#ecebe6]",
        !@checked? && @row_class
      ]}
    >
      <div class="flex flex-wrap items-start justify-between gap-x-2 gap-y-3">
        <div class="flex min-w-0 flex-none items-center gap-[11px]">
          <div :if={@show_checkboxes} class="flex-none">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:checkbox}
              phx-click="toggle_select"
              phx-value-id={@record.id}
              phx-target={@myself}
              name="select_card"
              value={@record.id}
              checked={@checked?}
              class="gervaz-media-checkbox size-4 cursor-pointer rounded accent-[#5b57d6]"
            />
          </div>

          <span class="grid size-11 flex-none place-items-center rounded-[13px] bg-[#f1edfb] text-[#7a5bd0]">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-user-group"
              class="size-[22px]"
            />
          </span>
        </div>

        <div
          :if={@visible_row_actions != []}
          data-role="col-actions"
          class="ms-auto flex min-w-0 items-center [&>div]:flex [&>div]:flex-wrap [&>div]:items-center [&>div]:justify-end [&>div]:gap-x-2.5 [&>div]:gap-y-1.5"
        >
          <Gervaz.render_row_actions
            row_actions={@visible_row_actions}
            record={@record}
            static={@static}
            state={@state}
            myself={@myself}
          />
        </div>
      </div>

      <div class="mt-[14px] flex flex-wrap items-center gap-2">
        <span class="font-['Space_Grotesk'] text-[15.5px] font-semibold text-[#17161a]">
          {@record.name}
        </span>

        <span class={[
          "rounded-[20px] px-2 py-[2px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
          @status.chip
        ]}>
          {Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", @status.label)}
        </span>
      </div>

      <div class="mt-1 text-[12px] font-medium text-[#8a877f]">
        {dgettext("mishka_gervaz", "%{count} members", count: @members_count)}
      </div>

      <%!-- The members' faces, overlapping. `mb-4` is the floor to the footer rule: the footer is
            `mt-auto`, which collapses on a full card and would otherwise sit the faces on the line. --%>
      <div :if={@members_shown != []} class="mb-4 mt-3 flex items-center -space-x-2">
        <span
          :for={{member, index} <- Enum.with_index(@members_shown)}
          title={member_name(member)}
          class={[
            "grid size-[30px] place-items-center rounded-full border-2 border-white font-['Space_Grotesk'] text-[11px] font-bold",
            member_tint(index)
          ]}
        >
          {member_initial(member)}
        </span>

        <span
          :if={@members_rest > 0}
          class="grid size-[30px] place-items-center rounded-full border-2 border-white bg-[#f2f1ec] text-[11px] font-bold text-[#8a877f]"
        >
          +{@members_rest}
        </span>
      </div>

      <div class={[
        "mt-auto flex items-center gap-2 border-t border-[#f4f3ee] pt-3.5",
        @members_shown == [] && "mt-4"
      ]}>
        <div class="flex min-w-0 items-center gap-4">
          <span class="inline-flex items-center gap-[5px] text-[11px] font-semibold text-[#a8a5a0]">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-user-group"
              class="size-[13px]"
            />
            {dgettext("mishka_gervaz", "%{count} members", count: @members_count)}
          </span>

          <span class="inline-flex items-center gap-[5px] text-[11px] font-semibold text-[#a8a5a0]">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-users"
              class="size-[13px]"
            />
            {dgettext("mishka_gervaz", "%{count} followers", count: @followers)}
          </span>
        </div>

        <span
          :if={@site}
          title={@site}
          class="ms-auto inline-flex max-w-[112px] flex-none items-center gap-[5px] rounded-md border border-[#e4e2f7] bg-[#f2f1fc] px-1.5 py-[3px] text-[10.5px] font-semibold text-[#4f4bcc]"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-globe-alt"
            class="size-[11px] flex-none"
          />
          <span class="truncate">{@site}</span>
        </span>
      </div>
    </div>
    """
  end

  @doc """
  How a team's status badge reads and what colour it wears.

  One entry per value of the `status` attribute, falling back to `:draft` — the attribute's own
  default.
  """
  @spec status_badge(map()) :: %{label: String.t(), chip: String.t()}
  def status_badge(%{status: status}) when is_map_key(@statuses, status), do: @statuses[status]
  def status_badge(_record), do: @statuses.draft

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  @doc "The tint a member's face wears at a given position, cycling so neighbours never match."
  @spec member_tint(non_neg_integer()) :: String.t()
  def member_tint(index), do: Enum.at(@member_tints, rem(index, length(@member_tints)))

  @doc """
  The whole face palette, in order, for the `:avatars` column type to cycle itself.

  The table row draws the same stack this card does, so it takes the palette from here rather than
  keeping a second copy that would drift.
  """
  @spec member_tints() :: [String.t()]
  def member_tints, do: @member_tints

  @doc """
  The team's members, always a list.

  Only the read the viewer is entitled to is preloaded — a tenant gets `members`, a master the
  tenancy-bypassing alias — so an unloaded relationship (a truthy `%Ash.NotLoaded{}`) becomes an
  empty list rather than a render crash.
  """
  @spec members(map()) :: [map()]
  def members(%{members: members}) when is_list(members), do: members
  def members(_record), do: []

  @doc "A member's display name, or a dash when the join row has no blogger."
  @spec member_name(map()) :: String.t()
  def member_name(%{display_name: name}) when is_binary(name), do: name
  def member_name(_member), do: "—"

  @doc "The single letter a member's face shows."
  @spec member_initial(map()) :: String.t()
  def member_initial(member) do
    member
    |> member_name()
    |> String.first()
    |> case do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp site_name(%{site: %{name: name}}, %{master_user?: true}) when is_binary(name), do: name
  defp site_name(_record, _state), do: nil

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
