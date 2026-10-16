# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.RestoreVersion do
  @moduledoc """
  Restores a record to one of its own versions, named by the action's `:version_id` argument.

  A version of any other record, of this site or another, is refused with `refusal/1`, and a
  version that does not exist with a not-found error. Only the attributes in
  `:fields` are copied back, and never `site_id`, so a restore cannot move a record to another site.
  The check holds for a call made with `authorize?: false` too.

  ## Usage

      update :restore_version do
        accept []
        argument :version_id, :uuid, allow_nil?: false

        change {MishkaBlog.Resources.Changes.RestoreVersion,
                version: MishkaBlog.Tag.Version,
                fields: [:name, :slug, :description],
                label: "tag"}
      end

  ## Options

  * `:version` - Required. The record's version resource. It needs a `:get_any` read.
  * `:fields` - Required. The attributes a restore copies back.
  * `:label` - Required. How the refusal names the record, such as "tag".
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def init(opts) do
    case {opts[:version], opts[:fields], opts[:label]} do
      {version, fields, label}
      when is_atom(version) and not is_nil(version) and is_list(fields) and is_binary(label) ->
        {:ok, opts}

      _missing ->
        {:error, "version, fields and label are required"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    record_id = changeset.data.id

    case Ash.get(opts[:version], version_id, action: :get_any, authorize?: false) do
      {:ok, %{version_source_id: ^record_id, changes: changes}} ->
        restore(changeset, changes, List.delete(opts[:fields], :site_id))

      {:ok, _another_records_version} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :version_id,
            message: refusal(opts[:label])
          )
        )

      _missing ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Query.NotFound.exception(resource: opts[:version])
        )
    end
  end

  @doc """
  The refusal of a version that is another record's: "Version does not belong to this {label}.",
  translated in the `errors` domain of `MishkaCmsCore.Gettext` in the locale of the calling process,
  `label` translated there too. A preview of another record's version is refused with it as well.
  """
  @spec refusal(String.t()) :: String.t()
  def refusal(label) do
    dgettext("errors", "Version does not belong to this %{label}.",
      label: Gettext.dgettext(MishkaCmsCore.Gettext, "errors", label)
    )
  end

  defp restore(changeset, changes, fields) do
    by_name = Map.new(fields, &{Atom.to_string(&1), &1})

    changes
    |> snapshot()
    |> Enum.reduce(changeset, fn {key, value}, acc ->
      case Map.fetch(by_name, to_string(key)) do
        {:ok, field} -> Ash.Changeset.force_change_attribute(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp snapshot(changes) when is_map(changes), do: changes
  defp snapshot(changes) when is_binary(changes), do: Jason.decode!(changes)
  defp snapshot(_none), do: %{}
end
