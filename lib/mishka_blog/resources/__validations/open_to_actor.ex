# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Validations.OpenToActor do
  @moduledoc """
  Refuses a write onto a record its actor may not open — a comment, a rating or a bookmark on a
  locked post, a vote on a comment of one — with the message the action gives for a record that is
  not there, so the refusal tells nothing a reader may not know. Who may open it is what its page
  asks (`MishkaBlog.Resources.Preparations.OpenToActor.opens?/2`).

      validate {OpenToActor,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                lock: :effective_permissions,
                message: dgettext_noop("errors", "Post not found or does not belong to your site.")}

  A call made with `authorize?: false` is not checked, and a record that is not there is left to the
  action's own check of it.

  ## Options

  * `:field` - Required. The attribute naming the record.
  * `:resource` - Required. The resource it names.
  * `:lock` - Required. The attribute or calculation holding the permissions that record opens with.
  * `:message` - Required. The refusal.
  """
  use Ash.Resource.Validation

  alias MishkaBlog.Resources.Preparations

  @impl true
  def init(opts) do
    if Enum.all?([:field, :resource, :lock, :message], &Keyword.has_key?(opts, &1)),
      do: {:ok, opts},
      else: {:error, "field, resource, lock and message are required"}
  end

  @impl true
  def validate(_changeset, _opts, %{authorize?: false}), do: :ok

  def validate(changeset, opts, context) do
    with id when not is_nil(id) <- Ash.Changeset.get_attribute(changeset, opts[:field]),
         {:ok, record} <-
           Ash.get(opts[:resource], id,
             tenant: context.tenant,
             authorize?: false,
             load: loads(opts[:resource], opts[:lock])
           ),
         false <- Preparations.OpenToActor.opens?(Map.get(record, opts[:lock]), context.actor) do
      {:error, field: opts[:field], message: opts[:message]}
    else
      _open_or_unchecked -> :ok
    end
  end

  # An attribute is read with the record, a calculation loaded.
  defp loads(resource, lock),
    do: if(Ash.Resource.Info.attribute(resource, lock), do: [], else: [lock])
end
