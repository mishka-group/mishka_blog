# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.AutoPostingRestoreTest do
  @moduledoc """
  The auto posting restore actions of a site's admin and of a master: they put the record back to
  one of its own versions, refuse an archived record and answer a record that is not there with a
  not-found error.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.AutoPosting

  setup do
    site = create_site!()

    %{
      site: site,
      admin: create_user_with_permissions!(["*"], site_id: site.id),
      master: create_user_with_permissions!(["*"])
    }
  end

  defp versioned(site) do
    record = create_auto_posting!(site_id: site.id, name: "First", plugin: "twitter")
    first = first_version(AutoPosting.Version, record.id)

    record
    |> Ash.Changeset.for_update(:update, %{name: "Second"}, tenant: site.id, authorize?: false)
    |> Ash.update!()

    {record, first}
  end

  defp restore(:site, record, version, actor) do
    AutoPosting
    |> Ash.ActionInput.for_action(
      :restore_version_api,
      %{id: record.id, version_id: version.id},
      actor: actor,
      tenant: record.site_id
    )
    |> Ash.run_action()
  end

  defp restore(:master, record, version, actor) do
    AutoPosting
    |> Ash.ActionInput.for_action(
      :master_restore_version_api,
      %{id: record.id, version_id: version.id},
      actor: actor
    )
    |> Ash.run_action()
  end

  # The site read leaves an archived record out, so for a site's admin it is simply not there; the
  # master read finds it and the action says why it is not restored.
  defp archived_refusal?(:site, error), do: match?(%Ash.Error.Query.NotFound{}, error)

  defp archived_refusal?(:master, error) do
    match?(
      %Ash.Error.Changes.InvalidAttribute{
        field: :archived_at,
        message: "Cannot restore version of archived auto-posting. Please unarchive it first."
      },
      error
    )
  end

  for scope <- [:site, :master] do
    describe "#{scope} restore" do
      test "puts the record back to its own version", %{site: site, admin: admin, master: master} do
        {record, first} = versioned(site)
        actor = if unquote(scope) == :site, do: admin, else: master

        assert {:ok, restored} = restore(unquote(scope), record, first, actor)
        assert restored.id == record.id
        assert restored.name == "First"
      end

      test "answers a record that is not there with not found", %{
        site: site,
        admin: admin,
        master: master
      } do
        {record, first} = versioned(site)
        actor = if unquote(scope) == :site, do: admin, else: master

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 restore(unquote(scope), %{record | id: Ash.UUID.generate()}, first, actor)

        assert Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
      end

      test "does not restore a record that is archived", %{
        site: site,
        admin: admin,
        master: master
      } do
        {record, first} = versioned(site)
        actor = if unquote(scope) == :site, do: admin, else: master

        record
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 restore(unquote(scope), record, first, actor)

        assert [error] = errors
        assert archived_refusal?(unquote(scope), error)
      end
    end
  end
end
