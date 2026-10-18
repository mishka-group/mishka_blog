# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Validations.NotItsOwnParent do
  @moduledoc """
  Refuses an update that makes a record its own parent: the attribute `:field` may not hold the
  record's own id. Any other record, or none, is let through. The refusal is `:message` on `:field`.

      validate {MishkaBlog.Resources.Validations.NotItsOwnParent,
                field: :parent_tag_id,
                message: dgettext_noop("errors", "Tag cannot be its own parent.")}

  It reads the id of the record being updated, so it belongs on an update action.

  ## Options

  * `:field` - Required. The attribute holding the parent's id.
  * `:message` - Required. The refusal.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if Enum.all?([:field, :message], &Keyword.has_key?(opts, &1)),
      do: {:ok, opts},
      else: {:error, "field and message are required"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    parent_id = Ash.Changeset.get_attribute(changeset, opts[:field])

    if not is_nil(parent_id) and parent_id == changeset.data.id,
      do: {:error, field: opts[:field], message: opts[:message]},
      else: :ok
  end
end
