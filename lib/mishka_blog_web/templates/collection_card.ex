# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Templates.CollectionCard do
  @moduledoc """
  The collections grid: one card per collection, in as many columns as fit the screen.

  Declared only by `MishkaBlog.Collection`, and it reads that record directly rather than by column
  position — a card is a specific shape (a folder tile beside its actions, a title over its blurb, and a
  footer weighing posts against versions) that a generic position mapping cannot describe. The
  resource's columns stay the field-selection contract and the vocabulary the table view sorts by.

  ## The grid is intrinsic, not stepped

  The design draws three columns and the prototype steps down to two, which leaves a phone showing two
  cramped cards with their actions cut off. Here the track list is
  `repeat(auto-fill, minmax(min(100%, 280px), 1fr))`: a card never goes below 280px unless the viewport
  itself is narrower, so the count falls from three to two to one on its own, at whatever width the
  content actually needs. No breakpoint to miss, and none to get wrong.

  ## Features
  - `:filter` - the labelled filter row: search, site, status, language
  - `:select` - per-card selection for bulk operations, beside the Featured-only switch
  - `:bulk_actions` - bulk actions on the selected cards
  - `:paginate` - the page-size picker and numbered pages under the grid

  The furniture around the cards is `MishkaCmsCoreWeb.Templates.CardChrome`, shared with the document
  card pages. Pairs with `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws the archive switch, the view
  switch and the row actions.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaBlogWeb.Templates.CardRecord
  alias MishkaBlogWeb.Templates.EditionChips
  alias MishkaCmsCore.LanguageAccent
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  # The row is one line that must not reflow. The card names its own language plus this many siblings,
  # and anything past that waits behind a "+N" the reader can open.
  @editions_shown 2

  @statuses %{
    active: %{
      label: dgettext_noop("mishka_gervaz", "Active"),
      chip: "bg-[#e6f6ee] text-[#177a53]"
    },
    draft: %{label: dgettext_noop("mishka_gervaz", "Draft"), chip: "bg-[#fbf1df] text-[#a5691a]"},
    archived: %{
      label: dgettext_noop("mishka_gervaz", "Archived"),
      chip: "bg-[#f2f1ec] text-[#6d6a63]"
    }
  }

  @impl true
  def name, do: :card_grid

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc """
  The switcher draws this glyph for the card view. It is the grid of four squares the design uses, and
  `MishkaGervaz.UIAdapters.Tailwind.switcher_icon_class/1` renders it inline — the runtime CSS compiler
  cannot emit a mask for a name it only sees at runtime.
  """
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Card grid for collections")

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
    <div class="mishka-gervaz-collection-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="grid items-start gap-4 grid-cols-[repeat(auto-fill,minmax(min(100%,280px),1fr))]"
        data_role="col-grid"
        empty_label={dgettext("mishka_gervaz", "0 collections")}
        empty_icon="hero-folder"
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
  One collection card.

  The head row wraps rather than shrinking: on a card narrow enough that the folder tile and the three
  labelled actions cannot share a line, the actions drop underneath instead of pushing "Delete" past the
  edge — which is what the prototype does at phone width.
  """
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    assigns =
      assigns
      |> assign(:checked?, checked?)
      |> assign(:row_class, Gervaz.custom_row_class(assigns.static, record))
      |> assign(:status, status_badge(record))
      |> assign(:accent, LanguageAccent.of(record))
      |> assign(:editions, EditionChips.editions(record))
      |> assign(:editions_shown, @editions_shown)
      |> assign(:posts, count(record, :post_count))
      |> assign(:versions, count(record, :version_count))
      |> assign(:site, site_name(record))
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="colcard"
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

          <span class="grid size-[38px] flex-none place-items-center rounded-[11px] bg-[#eef1fc] text-[#4f4bcc]">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-folder"
              class="size-[19px]"
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

      <.link
        navigate={posts_path(@record)}
        class="mt-[15px] block font-['Space_Grotesk'] text-[15px] font-semibold text-[#17161a] transition-colors hover:text-[#4f4bcc]"
      >
        {@record.name}
      </.link>

      <div class="mt-[5px] min-h-[34px] text-[12px] font-medium leading-[1.5] text-[#8a877f]">
        {@record.description}
      </div>

      <%!-- `mb-4` is the floor under the row — the footer below is `mt-auto`, which collapses to
            nothing on a card whose content already fills it, leaving the chips sitting on the rule. --%>
      <EditionChips.row
        id={@id}
        record={@record}
        editions={@editions}
        accent={@accent}
        shown={@editions_shown}
        class="mb-4 mt-3"
      />

      <%!-- One line, always: the counts give up width first and the site name truncates, rather than
            the badges dropping to a second row and stretching every card in the track. --%>
      <div class="mt-auto flex items-center gap-2 border-t border-[#f4f3ee] pt-3.5">
        <span class="min-w-0 shrink truncate text-[11px] font-semibold text-[#a8a5a0]">
          {dgettext("mishka_gervaz", "%{posts} posts · %{versions} versions",
            posts: @posts,
            versions: @versions
          )}
        </span>

        <div class="ms-auto flex flex-none items-center gap-1.5">
          <span class={[
            "rounded-md px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
            @status.chip
          ]}>
            {Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", @status.label)}
          </span>

          <span
            :if={@site}
            title={@site}
            class="inline-flex max-w-[112px] items-center gap-[5px] rounded-md border border-[#e4e2f7] bg-[#f2f1fc] px-1.5 py-[3px] text-[10.5px] font-semibold text-[#4f4bcc]"
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
    </div>
    """
  end

  @doc """
  How a collection's status badge reads and what colour it wears.

  One entry per value of the `status` attribute, falling back to `:draft` — the attribute's own default.
  """
  @spec status_badge(map()) :: %{label: String.t(), chip: String.t()}
  def status_badge(record), do: CardRecord.status_badge(record, @statuses, :draft)

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  defdelegate count(record, key), to: CardRecord

  defp site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name(_record), do: nil

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)

  @doc """
  Where a collection's title goes: the posts page, narrowed to that collection.

  `posts_filter_collection_id` is the URL contract `MishkaBlog.BlogPost`'s `url_sync` block declares
  (prefix `"posts"`), decoded back into filter state on arrival — so the destination opens with the
  Collection filter already applied and the admin can widen it from there. A plain string rather than
  `path/2` because a template module has no socket, matching
  `MishkaDocumentWeb.Templates.DocumentCard.edition_path/1`.
  """
  def posts_path(%{id: id}), do: "/admin/dashboard/blog/posts?posts_filter_collection_id=#{id}"
end
