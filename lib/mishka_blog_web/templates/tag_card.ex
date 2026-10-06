defmodule MishkaBlogWeb.Templates.TagCard do
  @moduledoc """
  The tags grid: one compact chip per tag, packed several to a row.

  Declared only by `MishkaBlog.Tag`, and it reads that record directly rather than by column
  position. A tag is small — a hash tile, a name, its language, and how many posts wear it — so the
  chip is dense and the actions fold into the kebab menu the resource already declares as a
  `dropdown` row-action layout, which `MishkaGervaz.Table.Templates.Shared.render_row_actions/1`
  draws.

  ## The grid is intrinsic, not stepped

  The track list is `repeat(auto-fill, minmax(min(100%, 220px), 1fr))`: a chip never goes below 220px
  unless the viewport is narrower, so the column count falls from four to two to one on its own.

  ## Features
  - `:filter` - the labelled filter row: search, site, language
  - `:select` - per-chip selection for bulk operations
  - `:bulk_actions` - bulk actions on the selected chips
  - `:paginate` - the page-size picker and Load more under the grid

  The furniture is `MishkaCmsCoreWeb.Templates.CardChrome` and the controls are
  `MishkaCmsCoreWeb.UIAdapters.Admin`, both shared with every other blog card page.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  # The hash tile is tinted from the tag name so the same tag always wears the same colour and a wall
  # of them reads as distinct rather than a grid of identical grey squares.
  @tints [
    "bg-[#eef1fc] text-[#4f4bcc]",
    "bg-[#eaf6ee] text-[#177a53]",
    "bg-[#fbf1df] text-[#a5691a]",
    "bg-[#f4ecfb] text-[#8a4bcc]",
    "bg-[#fbe9e7] text-[#b3433a]",
    "bg-[#e6f5f2] text-[#1f8f86]"
  ]

  @impl true
  def name, do: :tag_grid

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc "The switcher draws the grid-of-squares glyph, identical to every other blog card page."
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Chip grid for tags")

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
    <div class="mishka-gervaz-tag-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="grid items-start gap-3 grid-cols-[repeat(auto-fill,minmax(min(100%,220px),1fr))]"
        data_role="tag-grid"
        empty_label={dgettext("mishka_gervaz", "0 tags")}
        empty_icon="hero-hashtag"
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

  @doc "One tag chip."
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    assigns =
      assigns
      |> assign(:checked?, checked?)
      |> assign(:row_class, Gervaz.custom_row_class(assigns.static, record))
      |> assign(:tint, tint(record))
      |> assign(:posts, count(record, :post_count))
      |> assign(
        :has_actions?,
        Gervaz.has_user_visible_actions?(
          assigns.static.row_actions,
          assigns.static.row_action_dropdowns,
          state
        )
      )

    ~H"""
    <div
      id={@id}
      data-role="tagchip"
      class={[
        "flex items-center gap-2.5 rounded-[12px] border bg-white px-[13px] py-[11px] shadow-[0_1px_2px_rgba(30,28,24,0.03)] transition-colors",
        (@checked? && "border-[#dcdbf5] ring-1 ring-[#5b57d6]") ||
          "border-[#ecebe6] hover:border-[#dcdbf5]",
        !@checked? && @row_class
      ]}
    >
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
          class="gervaz-media-checkbox size-[15px] cursor-pointer rounded accent-[#5b57d6]"
        />
      </div>

      <span class={[
        "grid size-6 flex-none place-items-center rounded-[7px] font-['Space_Grotesk'] text-[13px] font-bold",
        @tint
      ]}>
        #
      </span>

      <span class="min-w-0 flex-1 truncate text-[12.5px] font-semibold text-[#1b1a18]">
        {@record.name}
      </span>

      <span class="flex-none rounded-[5px] bg-[#f2f1ec] px-1.5 py-[2px] text-[8.5px] font-bold uppercase tracking-[0.05em] text-[#8a877f]">
        {String.upcase(@record.language || "")}
      </span>

      <span class={[
        "flex-none text-end font-['Space_Grotesk'] text-[11px] font-bold",
        (@posts > 0 && "text-[#4f4bcc]") || "text-[#c3c0b8]"
      ]}>
        {@posts}
      </span>

      <%!-- The tag resource declares its actions as a `dropdown` layout, so this passes the whole
            static and lets Gervaz draw the kebab menu — the same call the table view makes. Reading
            the filtered flat list here would find nothing, since a dropdown's actions do not live in
            it. --%>
      <div
        :if={@has_actions?}
        data-role="tag-actions"
        class="flex flex-none items-center [&_button]:size-[22px] [&_button]:rounded-md"
      >
        <Gervaz.render_row_actions
          row_actions={@static.row_actions}
          record={@record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  @doc "The hash-tile tint, picked from the tag name so it never flickers between renders."
  @spec tint(map()) :: String.t()
  def tint(%{name: name}) when is_binary(name),
    do: Enum.at(@tints, :erlang.phash2(name, length(@tints)))

  def tint(_record), do: hd(@tints)

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
