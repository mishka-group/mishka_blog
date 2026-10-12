defmodule MishkaBlog.Resources.Changes.ContentFacts do
  @moduledoc """
  What a post's `content` says about it, worked out once, when the content is written — reading a
  post works out neither:

    * `content_components` — the components its markers name
      (`MishkaCmsCore.Runtime.ContentComponents.names/1`), `nil` when it names none. A site's
      stylesheet is built from them — see `MishkaBlog.Plugins.ContentComponents`.
    * `content_icons` — the icon classes it names, in a marker's attribute or in its HTML
      (`MishkaCmsCore.Runtime.ContentComponents.icons/1`), `nil` when it names none. The site's
      stylesheet carries a rule for each — see `MishkaBlog.Plugins.ContentComponents`.
    * `reading_time_minutes` — its words at 200 a minute, rounded up, never under 1.

  All three are worked out in a `before_action` hook, which runs after every change an action lists
  — the `guardedstruct` sanitizer and `MishkaBlog.Resources.Changes.HighlightCode` included — so
  they are read off the content that is stored. A write that leaves `content` alone leaves them
  alone, unless the post has no reading time yet — a row this change never saw — which any save
  fills.

  ## The stylesheet

  A write that makes a name or an icon live on its site — a published post names it now and did
  not before, and no other published post of the site names it — rebuilds the site's stylesheet,
  through `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.schedule/1`. The job is enqueued in the
  write's own transaction, so a write rolled back asks for nothing. A name or an icon dropped, or a
  post unpublished, rebuilds nothing.

  ## Usage

      update :update do
        change MishkaBlog.Resources.Changes.HighlightCode
        change MishkaBlog.Resources.Changes.ContentFacts
      end

  On an action that writes no content — `:publish` — only the stylesheet half has anything to do.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.ContentComponents

  @words_a_minute 200

  # What a site's stylesheet is built from, each a list a published post makes live.
  @styled [:content_components, :content_icons]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&facts/1)
    |> Ash.Changeset.after_action(&restyle/2)
  end

  defp facts(changeset) do
    case content_to_read(changeset) do
      content when is_binary(content) ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :content_components,
          stored(ContentComponents.names(content))
        )
        |> Ash.Changeset.force_change_attribute(
          :content_icons,
          stored(ContentComponents.icons(content))
        )
        |> Ash.Changeset.force_change_attribute(:reading_time_minutes, reading_time(content))

      _unchanged ->
        changeset
    end
  end

  defp content_to_read(changeset) do
    case Ash.Changeset.fetch_change(changeset, :content) do
      {:ok, content} -> content
      :error -> missing_facts(changeset)
    end
  end

  defp missing_facts(%{data: %{reading_time_minutes: nil}} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :content)

  defp missing_facts(_changeset), do: nil

  defp stored([]), do: nil
  defp stored(found), do: found

  @doc """
  Minutes `content` takes to read: its words at 200 a minute, rounded up, never under 1.
  """
  @spec reading_time(String.t()) :: pos_integer()
  def reading_time(content) when is_binary(content) do
    words =
      content |> HtmlSanitizeEx.strip_tags() |> String.split(~r/\s+/, trim: true) |> length()

    max(ceil(words / @words_a_minute), 1)
  end

  defp restyle(changeset, post) do
    case Enum.any?(@styled, &unstyled?(changeset.data, post, &1)) do
      true -> TailwindCompiler.schedule(post.site_id)
      false -> :ok
    end

    {:ok, post}
  end

  defp unstyled?(was, post, fact),
    do: was |> newly_live(post, fact) |> Enum.any?(&(not named_elsewhere?(post, fact, &1)))

  @doc """
  What `post` makes live of `fact` that `was` did not — its component names
  (`:content_components`, the default) or its icons (`:content_icons`): what a published post
  lists, less what the post published before the write already listed.
  """
  @spec newly_live(map(), map(), :content_components | :content_icons) :: [String.t()]
  def newly_live(was, post, fact \\ :content_components), do: live(post, fact) -- live(was, fact)

  defp live(%{status: :published} = post, fact) do
    case Map.get(post, fact) do
      listed when is_list(listed) -> listed
      _nothing -> []
    end
  end

  defp live(_post, _fact), do: []

  # READ AS THE SYSTEM, as the site's stylesheet is built: a post locked to some readers draws its
  # components and icons for them, so it is styled whoever reads it.
  defp named_elsewhere?(post, fact, value) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:public_list, %{}, tenant: post.site_id, authorize?: false)
    |> Ash.Query.filter(id != ^post.id and has(^ref(fact), ^value))
    |> Ash.exists?(tenant: post.site_id, authorize?: false)
  end
end
