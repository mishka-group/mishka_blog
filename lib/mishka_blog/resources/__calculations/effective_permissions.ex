# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Calculations.EffectivePermissions do
  @moduledoc """
  The permissions a post or a category opens with on its blog page, in its sitemap entry and
  wherever else a reader is let in, and those a comment is reached with:

    * a category — its own, else those of the nearest parent category that names some;
    * a post — its own, else those of every category it is filed under, each as that category
      opens with. Holding one of any of them is enough. A post in no locked category is public;
    * a comment — its post's.

  What a record names itself always wins over what it would take from above. A tag is only
  assigned to a post, so it locks nothing but its own page and has no such calculation.

  A category counts while it exists, whatever its status: setting a locked category to draft does
  not open the posts filed under it. A deleted one counts no more. The categories are read only
  for the records that name nothing themselves, one read per site for the whole batch.

      calculate :effective_permissions, {:array, :string}, {EffectivePermissions, kind: :post}
  """
  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaBlog.{Collection, PostCollection}

  @impl true
  def load(_query, opts, _context) do
    case opts[:kind] do
      :collection -> [:id, :site_id, :permissions, :parent_collection_id]
      :post -> [:id, :site_id, :permissions]
      :comment -> [:site_id, :post_id]
    end
  end

  @impl true
  def calculate(records, opts, _context) do
    open = Enum.reject(records, &own?/1)

    case opts[:kind] do
      :comment ->
        posts = post_locks(records)
        Enum.map(records, &Map.get(posts, &1.post_id, []))

      :collection ->
        trees = trees(Enum.filter(open, & &1.parent_collection_id))

        Enum.map(records, fn collection ->
          inherited(
            collection.permissions,
            collection.parent_collection_id,
            Map.get(trees, collection.site_id, %{})
          )
        end)

      :post ->
        filed = filed_under(open)
        trees = trees(Enum.filter(open, &Map.has_key?(filed, &1.id)))

        Enum.map(records, &post_permissions(&1, filed, trees))
    end
  end

  defp post_permissions(%{permissions: [_ | _] = own}, _filed, _trees), do: own

  defp post_permissions(post, filed, trees) do
    tree = Map.get(trees, post.site_id, %{})

    filed
    |> Map.get(post.id, [])
    |> Enum.flat_map(&inherited([], &1, tree))
    |> Enum.uniq()
  end

  # What each post these comments are on opens with, by the post's id, one read per site.
  defp post_locks(comments) do
    comments
    |> Enum.group_by(& &1.site_id, & &1.post_id)
    |> Enum.flat_map(fn {site_id, post_ids} ->
      MishkaBlog.BlogPost
      |> Ash.Query.filter(id in ^Enum.uniq(post_ids))
      |> Ash.Query.select([:id])
      |> Ash.Query.load(:effective_permissions)
      |> Ash.read!(tenant: site_id, authorize?: false, page: false)
      |> Enum.map(&{&1.id, &1.effective_permissions})
    end)
    |> Map.new()
  end

  defp own?(%{permissions: [_ | _]}), do: true
  defp own?(_record), do: false

  # Each post's categories, by the post's id.
  defp filed_under([]), do: %{}

  defp filed_under(posts) do
    ids = Enum.map(posts, & &1.id)

    PostCollection
    |> Ash.Query.filter(post_id in ^ids)
    |> Ash.Query.select([:post_id, :collection_id])
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.group_by(& &1.post_id, & &1.collection_id)
  end

  # Every category of each site these records are on, as `{parent_id, permissions}` by id.
  defp trees(records) do
    records
    |> Enum.map(& &1.site_id)
    |> Enum.uniq()
    |> Map.new(fn site_id ->
      tree =
        Collection
        |> Ash.Query.select([:id, :parent_collection_id, :permissions])
        |> Ash.read!(tenant: site_id, authorize?: false, page: false)
        |> Map.new(&{&1.id, {&1.parent_collection_id, &1.permissions}})

      {site_id, tree}
    end)
  end

  # Its own permissions when it names any, else those of the nearest one above it that does: `tree`
  # is `{parent_id, permissions}` by id, and leaving it, or meeting an id twice, ends the walk.
  defp inherited(own, parent_id, tree, seen \\ MapSet.new())

  defp inherited([_ | _] = own, _parent_id, _tree, _seen), do: own

  defp inherited(_none, parent_id, tree, seen) do
    with false <- MapSet.member?(seen, parent_id),
         {:ok, {grandparent_id, permissions}} <- Map.fetch(tree, parent_id) do
      inherited(permissions, grandparent_id, tree, MapSet.put(seen, parent_id))
    else
      _top -> []
    end
  end
end
