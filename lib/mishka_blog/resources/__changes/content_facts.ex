defmodule MishkaBlog.Resources.Changes.ContentFacts do
  @moduledoc """
  What a post's `content` says about it, worked out once, when the content is written — reading a
  post works out neither:

    * `content_components` — the components its markers name
      (`MishkaCmsCore.Runtime.ContentComponents.names/1`), `nil` when it names none. A site's
      stylesheet is built from them — see `MishkaBlog.Plugins.ContentComponents`.
    * `reading_time_minutes` — its words at 200 a minute, rounded up, never under 1.

  Both are worked out in a `before_action` hook, which runs after every change an action lists —
  the `guardedstruct` sanitizer and `MishkaBlog.Resources.Changes.HighlightCode` included — so they
  are read off the content that is stored. A write that leaves `content` alone leaves both alone,
  unless the post has no reading time yet — a row this change never saw — which any save fills.

  ## The stylesheet

  A write that makes a name live on its site — a published post names it now and did not before,
  and no other published post of the site names it — rebuilds the site's stylesheet, through
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.schedule/1`. The job is enqueued in the write's
  own transaction, so a write rolled back asks for nothing. A name dropped, or a post unpublished,
  rebuilds nothing.

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
        |> Ash.Changeset.force_change_attribute(:content_components, stored_names(content))
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

  defp stored_names(content) do
    case ContentComponents.names(content) do
      [] -> nil
      names -> names
    end
  end

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
    case newly_live(changeset.data, post) do
      [] -> :ok
      names -> rebuild(post, Enum.reject(names, &named_elsewhere?(post, &1)))
    end

    {:ok, post}
  end

  defp rebuild(_post, []), do: :ok
  defp rebuild(post, _unstyled), do: TailwindCompiler.schedule(post.site_id)

  @doc """
  The component names `post` makes live that `was` did not: the names of a published post, less
  the names the post published before the write already had.
  """
  @spec newly_live(map(), map()) :: [String.t()]
  def newly_live(was, post), do: live_names(post) -- live_names(was)

  defp live_names(%{status: :published, content_components: names}) when is_list(names),
    do: names

  defp live_names(_post), do: []

  # READ AS THE SYSTEM, as the site's stylesheet is built: a post locked to some readers draws its
  # components for them, so it is styled whoever reads it.
  defp named_elsewhere?(post, name) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:public_list, %{}, tenant: post.site_id, authorize?: false)
    |> Ash.Query.filter(id != ^post.id and fragment("? = ANY(?)", ^name, content_components))
    |> Ash.exists?(tenant: post.site_id, authorize?: false)
  end
end
