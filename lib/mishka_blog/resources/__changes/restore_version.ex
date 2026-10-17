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

  @doc """
  The entries of a version's `changes` whose key names one of `fields`, keyed by that atom. A key
  that names no field is left out, so reading a version never creates an atom:

      known_changes(%{"name" => "Elixir", "junk" => 1}, [:name, :slug]) #=> %{name: "Elixir"}

  `changes` may be a map with string or atom keys, or its JSON; anything else, JSON that does not
  parse or is not an object included, reads as `%{}`.
  """
  @spec known_changes(map() | String.t() | nil, [atom()]) :: %{atom() => term()}
  def known_changes(changes, fields) do
    by_name = Map.new(fields, &{Atom.to_string(&1), &1})

    for {key, value} <- snapshot(changes),
        {:ok, field} <- [Map.fetch(by_name, to_string(key))],
        into: %{},
        do: {field, value}
  end

  @doc """
  Each of `records` as it was in the version `version_id` of `version`, read with `opts` (the
  caller's actor, tenant and `authorize?`) through the version's `:get_any` read:

      preview(results, MishkaBlog.Tag.Version, version_id, "tag", Ash.Scope.to_opts(context))

  A version that belongs to another record is refused with `refusal/1` of `label`, and one that
  cannot be read comes back as the read's own error. Neither raises.
  """
  @spec preview([struct()], module(), String.t(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, Exception.t()}
  def preview(records, version, version_id, label, opts) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, previews} ->
      case Ash.get(version, version_id, Keyword.put(opts, :action, :get_any)) do
        {:ok, %{version_source_id: source_id, changes: changes}} when source_id == record.id ->
          fields = record |> Map.from_struct() |> Map.keys()
          {:cont, {:ok, [struct(record, known_changes(changes, fields)) | previews]}}

        {:ok, _another_records_version} ->
          {:halt, {:error, refused(label)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, previews} -> {:ok, Enum.reverse(previews)}
      error -> error
    end
  end

  @doc """
  `changes` with the string value of `field` read through the attribute's own type on `resource`:
  `"active"` becomes `:active` for an atom attribute. A value the type refuses is dropped, so the
  record keeps its current one; a field that is absent or not a string is left as it is.
  """
  @spec cast_field(%{atom() => term()}, Ash.Resource.t(), atom()) :: %{atom() => term()}
  def cast_field(changes, resource, field) do
    with {:ok, value} when is_binary(value) <- Map.fetch(changes, field),
         %{type: type, constraints: constraints} <- Ash.Resource.Info.attribute(resource, field) do
      case Ash.Type.cast_input(type, value, constraints) do
        {:ok, cast} -> Map.put(changes, field, cast)
        _refused -> Map.delete(changes, field)
      end
    else
      _absent -> changes
    end
  end

  defp refused(label) do
    Ash.Error.Invalid.exception(
      errors: [
        Ash.Error.Query.InvalidArgument.exception(field: :version_id, message: refusal(label))
      ]
    )
  end

  defp restore(changeset, changes, fields) do
    changes
    |> known_changes(fields)
    |> Enum.reduce(changeset, fn {field, value}, acc ->
      Ash.Changeset.force_change_attribute(acc, field, value)
    end)
  end

  defp snapshot(changes) when is_map(changes), do: changes

  defp snapshot(changes) when is_binary(changes) do
    case Jason.decode(changes) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_an_object -> %{}
    end
  end

  defp snapshot(_none), do: %{}
end
