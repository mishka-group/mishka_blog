# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.NotItsOwnParentTest do
  @moduledoc """
  An update that names a tag, a collection or a comment as its own parent is refused on the parent
  field with that record's message, through the update of a site and the update of a master; any
  other record, or none, is taken as the parent.
  """
  use MishkaBlog.DataCase, async: false

  @cases [
    {:create_blog_tag!, :parent_tag_id, "Tag cannot be its own parent."},
    {:create_collection!, :parent_collection_id, "Collection cannot be its own parent."},
    {:create_comment!, :parent_comment_id, "Comment cannot be its own parent."}
  ]

  defp record(factory, site), do: apply(MishkaBlog.Test.Factory, factory, [[site_id: site.id]])

  defp save(record, :update, params) do
    record
    |> Ash.Changeset.for_update(:update, params, tenant: record_site(record), authorize?: false)
    |> Ash.update()
  end

  defp save(record, :master_update, params) do
    record
    |> Ash.Changeset.for_update(:master_update, params, authorize?: false)
    |> Ash.update()
  end

  defp record_site(%{site_id: site_id}), do: site_id

  for {factory, field, message} <- @cases, action <- [:update, :master_update] do
    test "#{factory} #{action}: its own id as the parent is refused on #{field}" do
      record = record(unquote(factory), create_site!())

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               save(record, unquote(action), %{unquote(field) => record.id})

      assert Enum.any?(errors, fn error ->
               Map.get(error, :field) == unquote(field) and
                 Map.get(error, :message) == unquote(message)
             end)
    end

    test "#{factory} #{action}: another record as the parent is taken" do
      site = create_site!()
      record = record(unquote(factory), site)
      parent = record(unquote(factory), site)

      assert {:ok, updated} = save(record, unquote(action), %{unquote(field) => parent.id})
      assert Map.fetch!(updated, unquote(field)) == parent.id
    end

    test "#{factory} #{action}: no parent is taken" do
      record = record(unquote(factory), create_site!())

      assert {:ok, updated} = save(record, unquote(action), %{unquote(field) => nil})
      assert Map.fetch!(updated, unquote(field)) == nil
    end
  end
end
