defmodule MishkaBlogWeb.Templates.EditionChips do
  @moduledoc """
  The language chips of a translated blog record: one per edition, the record's own first, each
  opening that edition.

  The post, collection and tag lists show one row per document rather than one per translation
  (`MishkaCmsCore.LanguageEditions`), so these chips are the way to a translation without searching
  for it. A card draws them as `row/1`, a table row as `inline/1`; both click `show_edition` with the
  edition's id, which the list's page answers.

  The siblings are read off the record's `language_variants` (or `master_language_variants`), so the
  table has to preload them — see `editions/1`.

  See `MishkaBlogWeb.Templates.CollectionCard` and `MishkaBlogWeb.Templates.PostCard`.
  """

  use Phoenix.Component
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.{LanguageAccent, LanguageEditions}
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared

  @chip "inline-flex items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold transition-opacity hover:opacity-70"
  @toggle "rounded-[20px] border border-[#e0ddd6] bg-[#f4f3ef] py-[3px] text-[9.5px] font-bold text-[#6d6a63] transition-colors hover:bg-[#eceae4]"

  @doc """
  A record's sibling editions — the same record in other languages — each with its own colour.

  Needs the sibling relationship loaded; a record that has no group, or whose siblings did not
  arrive, has none.
  """
  @spec editions(map()) :: [map()]
  def editions(record) do
    LanguageEditions.editions(record, &%{accent: LanguageAccent.of(&1)})
  end

  @doc """
  The labelled chip row of a card.

  The label and the first `shown` chips share one line that never reflows: the rest open underneath
  rather than pushing the row they came from. `id` is the card's own DOM id, which scopes the
  `-editions-more`, `-editions-less` and `-editions-rest` elements the toggle flips
  (`MishkaCmsCoreWeb.Templates.CardChrome.expand_editions/1`).
  """
  attr :id, :string, required: true
  attr :record, :map, required: true
  attr :editions, :list, required: true
  attr :accent, :map, required: true
  attr :shown, :integer, default: 2
  attr :event, :string, default: "show_edition"
  attr :class, :any, default: nil

  def row(assigns) do
    assigns =
      assigns
      |> assign(:editions_shown, Enum.take(assigns.editions, assigns.shown))
      |> assign(:editions_rest, Enum.drop(assigns.editions, assigns.shown))
      |> assign(:chip, @chip)
      |> assign(:toggle, @toggle)

    ~H"""
    <div :if={@editions != []} id={"#{@id}-editions"} class={@class}>
      <div class="flex items-center gap-2">
        <span class="flex-none text-[9px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]">
          {dgettext("mishka_gervaz", "Languages")}
        </span>

        <.chip
          id={"#{@id}-edition-#{@record.language}"}
          event={@event}
          edition_id={@record.id}
          language={@record.language || ""}
          accent={@accent}
          class="flex-none"
        />

        <.chip
          :for={edition <- @editions_shown}
          id={"#{@id}-edition-#{edition.language}"}
          event={@event}
          edition_id={edition.id}
          language={edition.language}
          accent={edition.accent}
          class="flex-none"
        />

        <button
          :if={@editions_rest != []}
          type="button"
          id={"#{@id}-editions-more"}
          phx-click={Shared.expand_editions(@id)}
          title={dgettext("mishka_gervaz", "Show every language")}
          class={["inline-flex flex-none items-center px-2", @toggle]}
        >
          +{length(@editions_rest)}
        </button>

        <button
          :if={@editions_rest != []}
          type="button"
          id={"#{@id}-editions-less"}
          phx-click={Shared.collapse_editions(@id)}
          title={dgettext("mishka_gervaz", "Show fewer languages")}
          class={["hidden flex-none items-center px-2.5 leading-none", @toggle]}
        >
          −
        </button>
      </div>

      <div
        :if={@editions_rest != []}
        id={"#{@id}-editions-rest"}
        class="mt-[7px] hidden flex-wrap gap-[5px]"
      >
        <.chip
          :for={edition <- @editions_rest}
          id={"#{@id}-edition-#{edition.language}"}
          event={@event}
          edition_id={edition.id}
          language={edition.language}
          accent={edition.accent}
        />
      </div>
    </div>
    """
  end

  @doc """
  The chips of a table row's cell, all of them wrapping.

  `id` scopes the chips' DOM ids, so it has to differ between the rows of one page — the record's id
  does. Nothing is drawn when `editions` is empty, so the cell can fall back to a plain language badge.
  """
  attr :id, :string, required: true
  attr :record, :map, required: true
  attr :editions, :list, required: true
  attr :accent, :map, required: true
  attr :event, :string, default: "show_edition"

  def inline(assigns) do
    ~H"""
    <span :if={@editions != []} id={@id} class="inline-flex flex-wrap items-center gap-[5px]">
      <.chip
        id={"#{@id}-edition-#{@record.language}"}
        event={@event}
        edition_id={@record.id}
        language={@record.language || ""}
        accent={@accent}
      />
      <.chip
        :for={edition <- @editions}
        id={"#{@id}-edition-#{edition.language}"}
        event={@event}
        edition_id={edition.id}
        language={edition.language}
        accent={edition.accent}
      />
    </span>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :edition_id, :string, required: true
  attr :language, :string, required: true
  attr :accent, :map, required: true
  attr :class, :any, default: nil

  defp chip(assigns) do
    assigns = assign(assigns, :chip, @chip)

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@event}
      phx-value-id={@edition_id}
      title={Shared.edition_title(%{language: @language})}
      class={[@chip, @accent.chip, @class]}
    >
      <span class={["size-1 rounded-full", @accent.fill]}></span>
      {String.upcase(@language)}
    </button>
    """
  end
end
