# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Templates.BloggerCard do
  @moduledoc """
  The bloggers grid: one card per blogger, as many to a row as the viewport can hold.

  Declared only by `MishkaBlog.Blogger`, and it reads that record directly rather than by column
  position — a profile card is a specific shape (an avatar beside its actions, a name over its role
  and expertise, and a footer weighing posts against followers) that a generic position mapping
  cannot describe. The resource's columns stay the field-selection contract and the vocabulary the
  table view sorts by.

  ## No fabricated engagement

  The prototype's card ends in an "Engagement 86%" bar, but that figure is invented — the mock
  hardcodes it for every blogger and `MishkaBlog.Blogger` has no engagement metric. Rather than draw
  a bar off a number that does not exist, the footer shows the two figures that are real
  (`post_count` and `follower_count`) and the card carries a Publisher/Contributor badge from
  `can_publish_directly`, which is the page's actual axis — the "Can publish directly" filter and the
  publishing-permission model both turn on it.

  ## The grid is intrinsic, not stepped

  The track list is `repeat(auto-fill, minmax(min(100%, 300px), 1fr))`: a card never goes below
  300px unless the viewport itself is narrower, so the count falls from three to two to one on its
  own, at whatever width the content actually needs. No breakpoint to miss, and none to get wrong.

  ## Features
  - `:filter` - the labelled filter row: search, site, with "Can publish directly" as a switch
  - `:select` - per-card selection for bulk operations
  - `:bulk_actions` - bulk actions on the selected cards
  - `:paginate` - the page-size picker and Load more under the grid

  The furniture is `MishkaCmsCoreWeb.Templates.CardChrome` and the controls are
  `MishkaCmsCoreWeb.UIAdapters.Admin`, both shared with the collections and posts card pages.

  See `MishkaBlogWeb.Templates.CollectionCard` for the same shape holding a different record.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  # An avatar with no picture still needs a tile, and a wall of identical grey circles reads as a
  # loading state. The pair comes from the record's own id so it is stable across renders and pages.
  @avatars [
    "bg-[#eef1fc] text-[#4f4bcc]",
    "bg-[#eaf6ee] text-[#177a53]",
    "bg-[#fbf1df] text-[#a5691a]",
    "bg-[#f4ecfb] text-[#8a4bcc]",
    "bg-[#fbe9e7] text-[#b3433a]",
    "bg-[#e6f5f2] text-[#1f8f86]"
  ]

  @expertise_shown 3

  @impl true
  def name, do: :card_grid

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc "The switcher draws the grid-of-squares glyph for this view, as it does for collections."
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Card grid for bloggers")

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
    <div class="mishka-gervaz-blogger-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="grid items-start gap-4 grid-cols-[repeat(auto-fill,minmax(min(100%,300px),1fr))]"
        data_role="bl-grid"
        empty_label={dgettext("mishka_gervaz", "0 bloggers")}
        empty_icon="hero-user-circle"
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

  @doc """
  One blogger card.

  The head row wraps rather than shrinking: on a card narrow enough that the avatar and the three
  labelled actions cannot share a line, the actions drop underneath instead of pushing "Delete" past
  the edge — which is what the prototype does at phone width.
  """
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    expertise = expertise(record)

    assigns =
      assigns
      |> assign(:checked?, checked?)
      |> assign(:row_class, Gervaz.custom_row_class(assigns.static, record))
      |> assign(:avatar, avatar(record))
      |> assign(:initials, initials(record))
      |> assign(:publisher?, record.can_publish_directly == true)
      |> assign(:expertise, Enum.take(expertise, @expertise_shown))
      |> assign(:expertise_rest, length(expertise) - @expertise_shown)
      |> assign(:posts, count(record, :post_count))
      |> assign(:followers, count(record, :follower_count))
      |> assign(:site, site_name(record, state))
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="blcard"
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

          <span class={[
            "grid size-11 flex-none place-items-center rounded-full font-['Space_Grotesk'] text-[14px] font-bold",
            @avatar
          ]}>
            {@initials}
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

      <div class={[
        "mt-[14px] flex flex-wrap items-center gap-2",
        @expertise == [] && "mb-4"
      ]}>
        <span class="font-['Space_Grotesk'] text-[15.5px] font-semibold text-[#17161a]">
          {@record.display_name}
        </span>

        <span class={[
          "rounded-[20px] px-2 py-[2px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
          (@publisher? && "bg-[#eef1fc] text-[#4f4bcc]") || "bg-[#f4f3ef] text-[#8a877f]"
        ]}>
          {(@publisher? && dgettext("mishka_gervaz", "Publisher")) ||
            dgettext("mishka_gervaz", "Contributor")}
        </span>
      </div>

      <%!-- Expertise as chips rather than a comma string: the prototype runs them into one grey line,
            but they are the tags the blogger writes under, and a tag is a chip everywhere else here.
            `mb-4` is the floor under the row: the footer below is `mt-auto`, which collapses to nothing
            on a card whose content already fills it, so without this the chips sit on the rule. --%>
      <div :if={@expertise != []} class="mb-4 mt-2.5 flex flex-wrap gap-[5px]">
        <span
          :for={topic <- @expertise}
          class="inline-flex items-center rounded-[7px] bg-[#f4f3ef] px-2 py-[3px] text-[10.5px] font-semibold text-[#6d6a63]"
        >
          {topic}
        </span>

        <span
          :if={@expertise_rest > 0}
          class="inline-flex items-center rounded-[7px] bg-[#f4f3ef] px-2 py-[3px] text-[10.5px] font-semibold text-[#a8a5a0]"
        >
          +{@expertise_rest}
        </span>
      </div>

      <%!-- One line, always: Posts and Followers are the two figures that are real. `mt-auto` pins
            the footer to the card's bottom so every card in the track shares a baseline. --%>
      <div class="mt-auto flex items-center gap-2 border-t border-[#f4f3ee] pt-3.5">
        <div class="flex min-w-0 items-center gap-4">
          <span class="inline-flex items-center gap-[5px] text-[11px] font-semibold text-[#a8a5a0]">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-document-text"
              class="size-[13px]"
            />
            {dgettext("mishka_gervaz", "%{count} posts", count: @posts)}
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

  @doc "The avatar tint pair, picked from the record's id so it never flickers between renders."
  @spec avatar(map()) :: String.t()
  def avatar(%{id: id}) when is_binary(id),
    do: Enum.at(@avatars, :erlang.phash2(id, length(@avatars)))

  def avatar(_record), do: hd(@avatars)

  @doc "The two letters the avatar tile shows, from the blogger's display name."
  @spec initials(map()) :: String.t()
  def initials(%{display_name: name}) when is_binary(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  def initials(_record), do: "?"

  @doc "The blogger's expertise topics, always a list."
  @spec expertise(map()) :: [String.t()]
  def expertise(%{expertise_areas: topics}) when is_list(topics), do: topics
  def expertise(_record), do: []

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  # A tenant admin only ever sees their own site, so naming it on every card is noise; a master is
  # reading across sites and needs to know which one each blogger belongs to.
  defp site_name(%{site: %{name: name}}, %{master_user?: true}) when is_binary(name), do: name
  defp site_name(_record, _state), do: nil

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
