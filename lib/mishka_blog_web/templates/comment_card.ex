# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Templates.CommentCard do
  @moduledoc """
  The comments list: one full-width row per comment, stacked.

  Declared only by `MishkaBlog.Comment`, and it reads that record directly rather than by column
  position. It is `MishkaBlogWeb.Templates.PostCard` for a different record — same row shape, same
  chrome, same breakpoints — because a comment queue and a post queue are read the same way: who,
  where, what they said, and what you can do about it.

  ## Which post a comment is on

  Only one of `:post` and `:master_post` is ever loaded — the resource preloads the tenant
  relationship for a tenant admin and the tenancy-bypassing one for a master. The other comes back
  as `%Ash.NotLoaded{}`, which is truthy, so `post/1` picks whichever is actually a record rather
  than testing for nil.

  ## Features
  - `:filter` - the labelled filter row: search, site, status, post, with Pinned as a switch
  - `:select` - per-row selection for bulk operations
  - `:bulk_actions` - bulk actions on the selected rows
  - `:paginate` - the page-size picker and Load more under the list

  The furniture is `MishkaCmsCoreWeb.Templates.CardChrome` and the controls are
  `MishkaCmsCoreWeb.UIAdapters.Admin`, both shared with every other admin card page.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Localized
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  # Each status carries its chip AND a glyph — the "mark" the design shows beside the badge, so the
  # state reads at a glance without parsing the word: a check once approved, a flag when flagged.
  @statuses %{
    approved: %{
      label: dgettext_noop("mishka_gervaz", "Approved"),
      chip: "bg-[#e6f6ee] text-[#177a53]",
      mark: "hero-check-circle",
      mark_tone: "text-[#177a53]"
    },
    pending: %{
      label: dgettext_noop("mishka_gervaz", "Pending"),
      chip: "bg-[#fbf1df] text-[#a5691a]",
      mark: "hero-clock",
      mark_tone: "text-[#a5691a]"
    },
    flagged: %{
      label: dgettext_noop("mishka_gervaz", "Flagged"),
      chip: "bg-[#fbe9e7] text-[#b3433a]",
      mark: "hero-flag",
      mark_tone: "text-[#b3433a]"
    },
    spam: %{
      label: dgettext_noop("mishka_gervaz", "Spam"),
      chip: "bg-[#f2f1ec] text-[#6d6a63]",
      mark: "hero-shield-exclamation",
      mark_tone: "text-[#8a877f]"
    }
  }

  # An avatar with no picture still needs a tile, and a wall of identical grey ones reads as a
  # loading state. The tint comes from the record's own id so it is stable across renders and pages.
  @tints [
    "bg-[#eef1fc] text-[#3a5bc4]",
    "bg-[#eaf6ee] text-[#177a53]",
    "bg-[#fbf1df] text-[#a5691a]",
    "bg-[#f4ecfb] text-[#8a4bcc]",
    "bg-[#f0efea] text-[#6d6a63]"
  ]

  @impl true
  def name, do: :comment_card

  @impl true
  def label, do: dgettext("mishka_gervaz", "Cards")

  @doc "The switcher draws the grid-of-squares glyph, identical to every other blog card page."
  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Row list for comments")

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
    <div class="mishka-gervaz-comment-card">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="flex flex-col gap-2.5"
        data_role="bp-list"
        empty_label={dgettext("mishka_gervaz", "0 comments")}
        empty_icon="hero-chat-bubble-left-right"
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
  One comment row.

  The comment's text is the row's subject, so it gets two lines rather than the one a post excerpt
  gets — a moderator decides from the words, not from the metadata around them.
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
      |> assign(:initials, initials(record))
      |> assign(:author, author(record))
      |> assign(:post_title, post_title(record))
      |> assign(:date, Localized.date(record.inserted_at, :yMMMd))
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
        id={"#{@id}-initials"}
        data-role="bp-thumb"
        class={[
          "grid size-14 flex-none place-items-center rounded-[11px] font-['Space_Grotesk'] text-[15px] font-bold max-[560px]:size-10!",
          @tint
        ]}
      >
        {@initials}
      </span>

      <div class="min-w-0 flex-1">
        <%!-- Author, when, and — if it is — that it is pinned, on one line: the design puts the pin
              beside the name, not down in the meta, so a moderator sees a stuck comment first. --%>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span
            id={"#{@id}-author"}
            dir="auto"
            class="truncate font-['Space_Grotesk'] text-[13.5px] font-semibold text-[#17161a]"
          >
            {@author}
          </span>
          <span class="text-[11px] font-medium text-[#a8a5a0]">{@date}</span>

          <span
            :if={@record.is_pinned}
            class="inline-flex items-center gap-1 rounded-[5px] bg-[#f2f1fc] px-[7px] py-[2px] text-[9px] font-bold uppercase tracking-[0.03em] text-[#4f4bcc]"
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-bookmark-solid"
              class="size-2.5"
            />
            {dgettext("mishka_gervaz", "Pinned")}
          </span>
        </div>

        <div class="mt-[7px] line-clamp-2 text-[13px] font-medium leading-[1.5] text-[#3a382f]">
          {@record.content}
        </div>

        <div class="mt-2.5 flex flex-wrap items-center gap-2">
          <span class="text-[11px] font-semibold text-[#a8a5a0]">
            {dgettext("mishka_gervaz", "On:")}
          </span>
          <span :if={@post_title} class="min-w-0 truncate text-[11.5px] font-semibold text-[#4f4bcc]">
            {@post_title}
          </span>

          <span class={[
            "rounded-[5px] px-[9px] py-[2px] text-[9px] font-bold uppercase tracking-[0.03em]",
            @status.chip
          ]}>
            {Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", @status.label)}
          </span>

          <%!-- The status as a glyph too — the "marked" mark the design shows after the badge: a
                green check once approved, a flag when flagged, and so on. --%>
          <span
            class={["inline-flex", @status.mark_tone]}
            title={Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", @status.label)}
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name={@status.mark}
              class="size-[15px]"
            />
          </span>
        </div>
      </div>

      <%!-- Below a phone this leaves the author's line and takes one of its own under a rule, rather
            than wrapping into a right-aligned block that squeezes the comment to two words wide. --%>
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
  How a comment's moderation status reads and what colour it wears.

  One entry per value of the `status` attribute, falling back to `:pending` — the attribute's own
  default, and the state an unrecognised comment should be treated as.
  """
  @spec status_badge(map()) :: %{
          label: String.t(),
          chip: String.t(),
          mark: String.t(),
          mark_tone: String.t()
        }
  def status_badge(%{status: status}) when is_map_key(@statuses, status), do: @statuses[status]
  def status_badge(_record), do: @statuses.pending

  @doc "The avatar tint, picked from the record's id so it never flickers between renders."
  @spec tint(map()) :: String.t()
  def tint(%{id: id}) when is_binary(id), do: Enum.at(@tints, :erlang.phash2(id, length(@tints)))
  def tint(_record), do: hd(@tints)

  @doc """
  Who wrote the comment, for the reader whose read loaded it.

  The author's email when the reader may see it. For a master, the name of its blogger profile on
  the comment's site, else "Master". "Guest" for a comment written signed out, "Unknown" for an
  author the reader's read did not return. Load `:author`, `:author_profile` and `:author_master?`.
  """
  @spec author(map()) :: String.t()
  def author(record) do
    Helper.who(
      Map.get(record, :author),
      Map.get(record, :author_master?) == true,
      (Map.get(record, :author_id) && :unknown) || :guest,
      profile_name(record)
    )
  end

  defp profile_name(%{author_profile: %{display_name: name}}) when is_binary(name), do: name
  defp profile_name(_record), do: nil

  @doc "The two letters the avatar tile shows for an author."
  @spec initials(map()) :: String.t()
  def initials(record) do
    record
    |> author()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  @doc """
  The title of the post a comment sits under.

  Only one of `:post` and `:master_post` is loaded, so this finds whichever came back as a record —
  an unloaded relationship is a `%Ash.NotLoaded{}` struct, which is truthy and would otherwise win.
  """
  @spec post_title(map()) :: String.t() | nil
  def post_title(record) do
    Enum.find_value([:post, :master_post], fn key ->
      case Map.get(record, key) do
        %{title: title} when is_binary(title) -> title
        _absent -> nil
      end
    end)
  end

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
