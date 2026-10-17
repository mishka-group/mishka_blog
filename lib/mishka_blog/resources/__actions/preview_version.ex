# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Actions.PreviewVersion do
  @moduledoc """
  Previews a record as it was in one of its own versions, without restoring it: the generic action
  takes the record's id and a `:version_id` argument and returns the record with the version's
  values over it.

  The record is read as the caller, through `:master_get` and with no tenant when `:master` is
  set. A version of any other record is refused with
  `MishkaBlog.Resources.Changes.RestoreVersion.refusal/1`; a record or version that cannot be read
  comes back as the read's own error. Nothing raises, and nothing is saved.

  ## Usage

      action :preview_version, :struct do
        constraints instance_of: MishkaBlog.Team

        argument :team_id, :uuid, allow_nil?: false
        argument :version_id, :uuid, allow_nil?: false

        run {MishkaBlog.Resources.Actions.PreviewVersion,
             record: :team_id,
             version: MishkaBlog.Team.Version,
             fields: [:name, :slug, :status],
             cast: [:status],
             label: "team"}
      end

  ## Options

  * `:record` - Required. The argument that holds the record's id.
  * `:version` - Required. The record's version resource. It needs a `:get_any` read.
  * `:label` - Required. How the refusal names the record, such as "team".
  * `:fields` - The attributes taken from the version. Defaults to every field of the record.
  * `:cast` - Fields whose string value is read through the attribute's own type.
  * `:master` - Read the record through `:master_get` on every site. Defaults to `false`.
  """
  use Ash.Resource.Actions.Implementation

  alias MishkaBlog.Resources.Changes.RestoreVersion

  @impl true
  def run(input, opts, context) do
    record_id = Map.fetch!(input.arguments, Keyword.fetch!(opts, :record))
    version_id = input.arguments.version_id
    master? = opts[:master] == true

    with {:ok, record} when not is_nil(record) <-
           Ash.get(input.resource, record_id, record_opts(context, master?)),
         {:ok, [preview]} <-
           RestoreVersion.preview([record], opts, version_id, version_opts(context, master?)) do
      {:ok, preview}
    else
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: input.resource)}
      {:error, error} -> {:error, error}
    end
  end

  defp record_opts(context, true),
    do: Ash.Scope.to_opts(context, action: :master_get, tenant: nil)

  defp record_opts(context, false), do: Ash.Scope.to_opts(context)

  defp version_opts(context, true), do: Ash.Scope.to_opts(context, tenant: nil)
  defp version_opts(context, false), do: Ash.Scope.to_opts(context)
end
