defmodule MishkaBlogWeb.Templates.PostCard do
  @moduledoc """
  The blog posts list: one full-width row per post, stacked.

  Declared only by `MishkaBlog.BlogPost`, and it reads that record directly rather than by column
  position — a post row is a specific shape (a thumbnail beside a title over its site and date, an
  excerpt under its language, a stats line ending in a status badge, and a row of language chips)
  that a generic position mapping cannot describe. The resource's columns stay the field-selection
  contract and the vocabulary the table view sorts by.

  The list shows one row per post rather than one per translation
  (`MishkaCmsCore.LanguageEditions`); the chips under the stats line
  (`MishkaBlogWeb.Templates.EditionChips`) are the way to a translation without searching for it.

  ## The row folds rather than overflowing

  The prototype keeps the five actions on the title's line at every width, so on a phone they wrap
  into a right-aligned block that pushes the excerpt into a column two words wide. Here the actions
  drop to their own full-width line under a rule below 560px, and the thumbnail shrinks with them —
  the row keeps its reading order and nothing leaves the viewport.

  ## Features
  - `:filter` - the labelled filter row: search, site, status, language, with Featured as a switch
  - `:select` - per-row selection for bulk operations
  - `:bulk_actions` - bulk actions on the selected rows
  - `:paginate` - the page-size picker and Load more under the list

  The furniture around the rows is `MishkaCmsCoreWeb.Templates.CardChrome`, shared with the
  collections and document card pages. Pairs with `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws
  the archive switch, the view switch and the row actions.

  See `MishkaBlogWeb.Templates.CollectionCard` for the same shape as a grid.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaBlogWeb.Templates.EditionChips
  alias MishkaCmsCore.LanguageAccent
  alias MishkaCmsCore.Localized
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  @statuses %{
    published: %{
      label: dgettext_noop("mishka_gervaz", "Published"),
      chip: "bg-[#e6f6ee] text-[#177a53]"
    },
    draft: %{label: dgettext_noop("mishka_gervaz", "Draft"), chip: "bg-[#fbf1df] text-[#a5691a]"},
    scheduled: %{
      label: dgettext_noop("mishka_gervaz", "Scheduled"),
      chip: "bg-[#eeedfb] text-[#5b57d6]"
    },
    archived: %{
      label: dgettext_noop("mishka_gervaz", "Archived"),
      chip: "bg-[#fbe9e7] text-[#b3433a]"
    }
  }

  # The row is one line that must not reflow. The row names its own language plus this many siblings,
  # and anything past that waits behind a "+N" the reader can open.
  @editions_shown 3

  # A post with no image still needs a tile, and a wall of identical grey ones reads as a loading
  # state. The tint is picked from the record's own id so it is stable across renders and pages.
  @tints [
    "bg-[#f0efea]",
    "bg-[#eef1fc]",
    "bg-[#eaf6ee]",
    "bg-[#fbf1df]",
    "bg-[#f4ecfb]"
  ]

  @impl true
  def name, do: :post_card

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc """
  The switcher draws this glyph for the card view.

  The same grid-of-squares every blog card page uses, so the Table/Cards switch reads identically on
  posts, comments, collections and bloggers — the resource picking a different glyph would make the
  same control look like a different one from page to page. `switcher_icon_class/1` on the admin
  adapter has a clause per name, because the runtime CSS compiler cannot emit a mask for a name it
  only ever sees at runtime.
  """
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Row list for blog posts")

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
    <div class="mishka-gervaz-post-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="flex flex-col gap-2.5"
        data_role="bp-list"
        empty_label={dgettext("mishka_gervaz", "0 posts")}
        empty_icon="hero-newspaper"
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
  One post row.

  The tick sits level with the title rather than centred on the card, because a card's height is set
  by however long its excerpt runs and a centred tick drifts away from the thing it selects.
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
      |> assign(:tint, tint(record))
      |> assign(:accent, LanguageAccent.of(record))
      |> assign(:editions, EditionChips.editions(record))
      |> assign(:editions_shown, @editions_shown)
      |> assign(:site, site_name(record, state))
      |> assign(:date, date_label(record))
      |> assign(:views, count(record, :view_count))
      |> assign(:comments, count(record, :comment_count))
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="bp-row"
      class={[
        "flex items-start gap-3.5 rounded-[14px] border bg-white px-[18px] py-4 shadow-[0_1px_2px_rgba(30,28,24,0.04)]",
        "max-[560px]:flex-wrap! max-[560px]:gap-x-3!",
        (@checked? && "border-[#dcdbf5] ring-1 ring-[#5b57d6]") || "border-[#ecebe6]",
        !@checked? && @row_class
      ]}
    >
      <div :if={@show_checkboxes} class="mt-[22px] flex-none max-[560px]:mt-1!">
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

      <span
        data-role="bp-thumb"
        class={[
          "grid size-14 flex-none place-items-center overflow-hidden rounded-[11px] text-[#b8b5ad] max-[560px]:size-10!",
          @tint
        ]}
      >
        <%!-- Decorative: the title is right beside it. An empty alt also means a cover image whose
              file has gone missing collapses to the tinted tile instead of spilling the post's
              title across the thumbnail as broken-image text. --%>
        <img
          :if={@record.featured_image_url}
          src={@record.featured_image_url}
          alt=""
          class="size-full object-cover"
        />
        <.dynamic_component
          :if={!@record.featured_image_url}
          module={@static.ui_adapter}
          function={:icon}
          name="hero-photo"
          class="size-[22px]"
        />
      </span>

      <div class="min-w-0 flex-1">
        <div class="truncate font-['Space_Grotesk'] text-[14.5px] font-semibold text-[#17161a]">
          {@record.title}
        </div>

        <div class="mt-1 flex flex-wrap items-center gap-2">
          <span :if={@site} class="text-[11.5px] font-semibold text-[#4f4bcc]">{@site}</span>
          <span :if={@site} class="size-[3px] rounded-full bg-[#c3c0b8]"></span>
          <span class="text-[11.5px] font-medium text-[#a8a5a0]">{@date}</span>
        </div>

        <div :if={@record.excerpt} class="mt-[7px] truncate text-[12px] font-medium text-[#8a877f]">
          <span class="text-[10px] font-bold uppercase tracking-[0.04em] text-[#a8a5a0]">
            {String.upcase(@record.language || "")}:
          </span>
          {@record.excerpt}
        </div>

        <div class="mt-2.5 flex flex-wrap items-center gap-3.5">
          <span
            class="inline-flex items-center gap-[5px] text-[11px] font-semibold text-[#a8a5a0]"
            title={dgettext("mishka_gervaz", "Views")}
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-eye"
              class="size-[13px]"
            />
            {@views}
          </span>

          <%!-- The count is the way into this post's comments. The page owns the route, so this
                pushes an event rather than building a path: an event reaches the LiveView, which has
                the socket `MishkaCmsCore.Helpers.path/2` needs to honour a deployment prefix. --%>
          <button
            type="button"
            phx-click="show_post_comments"
            phx-value-id={@record.id}
            class="inline-flex items-center gap-[5px] text-[11px] font-semibold text-[#a8a5a0] transition-colors hover:text-[#4f4bcc]"
            title={dgettext("mishka_gervaz", "Review this post's comments")}
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-chat-bubble-left"
              class="size-[13px]"
            />
            {@comments}
          </button>

          <span class={[
            "rounded-md px-[9px] py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
            @status.chip
          ]}>
            {Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", @status.label)}
          </span>

          <span
            :if={@record.featured}
            class="text-[#e6b422]"
            title={dgettext("mishka_gervaz", "Featured")}
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-star-solid"
              class="size-3.5"
            />
          </span>
        </div>

        <EditionChips.row
          id={@id}
          record={@record}
          editions={@editions}
          accent={@accent}
          shown={@editions_shown}
          class="mt-2.5"
        />
      </div>

      <%!-- Below a phone this leaves the title's line and takes one of its own under a rule, rather
            than wrapping into a right-aligned block that squeezes the excerpt to two words wide. --%>
      <div
        :if={@visible_row_actions != []}
        data-role="bp-actions"
        class={[
          "flex flex-none items-center max-[980px]:flex-wrap! max-[980px]:justify-end!",
          "max-[560px]:mt-3! max-[560px]:w-full! max-[560px]:justify-start! max-[560px]:border-t!",
          "max-[560px]:border-[#f4f3ee]! max-[560px]:pt-3!",
          "[&>div]:flex [&>div]:flex-wrap [&>div]:items-center [&>div]:justify-end [&>div]:gap-x-3.5",
          "[&>div]:gap-y-2 max-[560px]:[&>div]:justify-start!"
        ]}
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
    """
  end

  @doc """
  How a post's status badge reads and what colour it wears.

  One entry per value of the `status` attribute, falling back to `:draft` — the attribute's own
  default.
  """
  @spec status_badge(map()) :: %{label: String.t(), chip: String.t()}
  def status_badge(%{status: status}) when is_map_key(@statuses, status), do: @statuses[status]
  def status_badge(_record), do: @statuses.draft

  @doc "The thumbnail tint for a post with no image, picked from its id so it never flickers."
  @spec tint(map()) :: String.t()
  def tint(%{id: id}) when is_binary(id), do: Enum.at(@tints, :erlang.phash2(id, length(@tints)))
  def tint(_record), do: hd(@tints)

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  @doc """
  When the post went out, or when it was written if it never did.

  A scheduled post reads as its due date, which is the only date about it worth showing.
  """
  @spec date_label(map()) :: String.t()
  def date_label(%{status: :scheduled, scheduled_publish_at: %DateTime{} = at}),
    do: Localized.date(at, :yMMMd)

  def date_label(%{published_at: %DateTime{} = at}), do: Localized.date(at, :yMMMd)
  def date_label(%{inserted_at: %DateTime{} = at}), do: Localized.date(at, :yMMMd)
  def date_label(_record), do: "—"

  # A tenant admin only ever sees their own site, so naming it on every row is noise; a master is
  # reading across sites and needs to know which one each post belongs to.
  defp site_name(%{site: %{name: name}}, %{master_user?: true}) when is_binary(name), do: name
  defp site_name(_record, _state), do: nil

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
