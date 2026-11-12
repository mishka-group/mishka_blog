# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.KeepOldAddress do
  @moduledoc """
  Keeps a shown row's old address working when a save moves it: the old address gets a 301 to the
  new one, written as a site redirect rule (`MishkaCmsCore.Runtime.Redirect`), as WordPress keeps a
  post's old slug.

  It works on a post, a category, a tag, a blogger and a team. The address is the one the site's
  page for its kind makes of the row (`MishkaBlog.Address.of/3`), before and after the save, so a new
  slug, language, publication date, number, parent category or (on a post page that names
  `:category`) first category all move it, whatever path the site gave the page. A row is moved
  only when it is shown before and after the save (`MishkaBlog.ShareCards.target/1`): a draft post,
  or one that is unpublished by the save, writes nothing. A blogger and a team are one row in every
  language, so they move at the address of each language the site publishes in.

  When the address moved, in the save's own transaction:

    * a rule at the new address (no query) is archived, since it would hide the row and loop back;
    * every redirect whose target is the old address is pointed at the new one, so A to B to C
      leaves A to C and B to C, never a chain;
    * the old address gets a 301 to the new one, unless a rule is already there: a rule someone
      wrote by hand is never overwritten.

  The rules are written with `authorize?: false`, as the system: the editor was allowed to save the
  row, and a blog editor need not hold the redirect section (`admin:dashboard:runtime:redirect`).
  They are the site's ordinary rules, listed in Admin, Redirects, where the owner can edit or
  delete them, and they reach `MishkaCmsCore.Runtime.States.RedirectsState` off the resource's own
  broadcasts, so a visitor's request reads them from memory.

  A save that moves nothing costs no query. On a page whose path names a post's `:category` or a
  category's whole chain (`*slug`), the row is loaded with that value before and after the save
  (`MishkaBlog.Address.loads/3`). Each moved address reads the site's rules once and writes only
  what changes.

  A category's posts and children are not followed: a new category slug writes the category's own
  rule only.

  ## Usage

      update :update do
        change MishkaBlog.Resources.Changes.KeepOldAddress
      end
  """
  use Ash.Resource.Change

  require Ash.Query

  alias MishkaBlog.{Address, ShareCards}
  alias MishkaCmsCore.Runtime.{Languages, Redirect, Redirects}

  @addressed [:slug, :language, :published_at, :number, :parent_collection_id]

  @moved_from :keep_old_address

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&remember/1)
    |> Ash.Changeset.after_action(&keep/2)
  end

  defp remember(%{data: row} = changeset) do
    with true <- moving?(changeset) and shown?(row),
         {:ok, old} <- addresses(row) do
      Ash.Changeset.put_context(changeset, @moved_from, old)
    else
      _stays -> changeset
    end
  end

  defp keep(%{context: %{@moved_from => old}}, result) do
    with true <- shown?(result),
         {:ok, new} <- addresses(result) do
      old
      |> Enum.flat_map(&moved(&1, new))
      |> Enum.reduce_while({:ok, result, []}, &move_one/2)
    else
      {:error, error} -> {:error, error}
      _not_shown -> {:ok, result}
    end
  end

  defp keep(_changeset, result), do: {:ok, result}

  defp move_one({from, to}, {:ok, result, notifications}) do
    case move(result.site_id, from, to) do
      {:ok, more} -> {:cont, {:ok, result, notifications ++ more}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  # An old address and the new one of the same language, each with its key as a rule stores it.
  defp moved({language, old}, new) do
    with {:ok, new} <- Map.fetch(new, language),
         {:ok, from} <- Redirects.normalize_path(old),
         {:ok, to} when to != from <- Redirects.normalize_path(new) do
      [{{from, old}, {to, new}}]
    else
      _not_moved -> []
    end
  end

  defp moving?(changeset) do
    Enum.any?(@addressed, &Ash.Changeset.changing_attribute?(changeset, &1)) or
      Map.has_key?(changeset.relationships, :tenant_collections)
  end

  defp shown?(row), do: ShareCards.target(row) != nil

  # The row's addresses by language: its own language's, or for a blogger and a team, which are one
  # row in every language, each language the site publishes in.
  defp addresses(row) do
    languages =
      case Map.get(row, :language) do
        nil -> Languages.site(row.site_id)
        language -> [language]
      end

    case Address.loads(row.__struct__, row.site_id, hd(languages)) do
      [] -> {:ok, filled(row, languages)}
      loads -> row |> Ash.load(loads, tenant: row.site_id, authorize?: false) |> loaded(languages)
    end
  end

  defp loaded({:ok, row}, languages), do: {:ok, filled(row, languages)}
  defp loaded(error, _languages), do: error

  defp filled(row, languages) do
    for language <- languages,
        address = Address.of(row, row.site_id, language),
        is_binary(address),
        into: %{},
        do: {language, address}
  end

  # One read finds the rules at either address and every redirect to the old one.
  defp move(site_id, {from, old}, {to, new}) do
    opts = [
      tenant: site_id,
      authorize?: false,
      return_notifications?: true,
      context: %{warn_on_transaction_hooks?: false}
    ]

    targets = Enum.uniq([old, from])

    with {:ok, rules} <- rules(from, to, targets, opts),
         {:ok, archived} <- archive(Enum.filter(rules, &at?(&1, to)), opts),
         {:ok, pointed} <- point(Enum.filter(rules, &pointing?(&1, targets, to)), new, opts),
         {:ok, created} <- create(Enum.any?(rules, &at?(&1, from)), from, new, opts) do
      {:ok, archived ++ pointed ++ created}
    end
  end

  defp rules(from, to, targets, opts) do
    Redirect
    |> Ash.Query.filter(
      (from_path in ^[from, to] and is_nil(from_query)) or (kind == :redirect and to in ^targets)
    )
    |> Ash.read(Keyword.take(opts, [:tenant, :authorize?]))
  end

  defp at?(rule, path), do: rule.from_path == path and is_nil(rule.from_query)

  defp pointing?(rule, targets, to),
    do: rule.kind == :redirect and rule.to in targets and not at?(rule, to)

  defp archive(rules, opts) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, notifications} ->
      case Ash.destroy(rule, opts) do
        {:ok, more} -> {:cont, {:ok, notifications ++ more}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp point(rules, new, opts) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, notifications} ->
      case Ash.update(rule, %{to: new}, opts) do
        {:ok, _rule, more} -> {:cont, {:ok, notifications ++ more}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create(true, _from, _new, _opts), do: {:ok, []}

  defp create(false, from, new, opts) do
    Redirect
    |> Ash.Changeset.for_create(
      :create,
      %{from_path: from, to: new, kind: :redirect, status: 301, active: true},
      Keyword.take(opts, [:tenant, :authorize?, :context])
    )
    |> Ash.create(Keyword.take(opts, [:return_notifications?]))
    |> case do
      {:ok, _rule, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, error}
    end
  end
end
