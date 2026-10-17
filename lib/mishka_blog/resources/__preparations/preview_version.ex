# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Preparations.PreviewVersion do
  @moduledoc """
  Turns a read of one record into a preview of it as it was in one of its own versions, named by the
  read's `:version_id` argument. Nothing is saved.

  The version is read as the caller, with no tenant when `:master` is set. A version of any other
  record is refused with `MishkaBlog.Resources.Changes.RestoreVersion.refusal/1`, and one that
  cannot be read comes back as the read's own error. Nothing raises.

  ## Usage

      read :preview_version do
        get? true

        argument :tag_id, :uuid, allow_nil?: false
        argument :version_id, :uuid, allow_nil?: false

        filter expr(id == ^arg(:tag_id))

        prepare {MishkaBlog.Resources.Preparations.PreviewVersion,
                 version: MishkaBlog.Tag.Version,
                 label: "tag"}
      end

  ## Options

  * `:version` - Required. The record's version resource. It needs a `:get_any` read.
  * `:label` - Required. How the refusal names the record, such as "tag".
  * `:fields` - The attributes taken from the version. Defaults to every field of the record.
  * `:cast` - Fields whose string value is read through the attribute's own type.
  * `:master` - Read the version with no tenant. Defaults to `false`.
  """
  use Ash.Resource.Preparation

  alias MishkaBlog.Resources.Changes.RestoreVersion

  @impl true
  def init(opts) do
    case {opts[:version], opts[:label]} do
      {version, label} when is_atom(version) and not is_nil(version) and is_binary(label) ->
        {:ok, opts}

      _missing ->
        {:error, "version and label are required"}
    end
  end

  @impl true
  def prepare(query, opts, context) do
    version_id = Ash.Query.get_argument(query, :version_id)
    read_opts = read_opts(context, opts[:master] == true)

    Ash.Query.after_action(query, fn _query, results ->
      RestoreVersion.preview(results, opts, version_id, read_opts)
    end)
  end

  defp read_opts(context, true), do: Ash.Scope.to_opts(context, tenant: nil)
  defp read_opts(context, false), do: Ash.Scope.to_opts(context)
end
