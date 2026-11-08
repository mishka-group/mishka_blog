# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.NextNumber do
  @moduledoc """
  Gives a new post the next free `number` of its site, the one past the highest any post of the
  site holds, archived ones included, so a number once given is never given again. A create that
  names its own number keeps it: that is how an import keeps a WordPress post's id, and the
  `unique_number_per_site` identity refuses one another post holds.

  It reads the highest number in a `before_action`, inside the create's transaction: one query per
  created post, none on a read.

      create :create do
        change MishkaBlog.Resources.Changes.NextNumber
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :number) do
      nil -> Ash.Changeset.before_action(changeset, &numbered/1)
      _named -> changeset
    end
  end

  defp numbered(changeset) do
    changeset.resource
    |> Ash.Query.for_read(:any_state, %{}, authorize?: false, tenant: changeset.tenant)
    |> Ash.max(:number, authorize?: false, tenant: changeset.tenant)
    |> case do
      {:ok, highest} ->
        Ash.Changeset.force_change_attribute(changeset, :number, (highest || 0) + 1)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
