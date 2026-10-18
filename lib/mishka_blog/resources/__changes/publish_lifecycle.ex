# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.PublishLifecycle do
  @moduledoc """
  Keeps a post's publish times in step with its `:status`.

  - A post whose status is `:published` and that has no `:published_at` gets the current time,
    truncated to the second.
  - A post whose status is `:scheduled` and that has no `:scheduled_publish_at` is refused with an
    error on that field.
  - Any other status is left alone.

  On a create it applies to every post. On an update it applies only when the status is changing, so
  saving an already published post never moves its `:published_at`.

  ## Usage

      create :create do
        change MishkaBlog.Resources.Changes.PublishLifecycle
      end

      update :update do
        change MishkaBlog.Resources.Changes.PublishLifecycle
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def change(%{action_type: :update} = changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status)

    if status == changeset.data.status,
      do: changeset,
      else: lifecycle(changeset, status)
  end

  def change(changeset, _opts, _context) do
    lifecycle(changeset, Ash.Changeset.get_attribute(changeset, :status))
  end

  defp lifecycle(changeset, :published) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :published_at)) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :published_at,
        DateTime.truncate(DateTime.utc_now(), :second)
      )
    else
      changeset
    end
  end

  defp lifecycle(changeset, :scheduled) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :scheduled_publish_at)) do
      Ash.Changeset.add_error(changeset,
        field: :scheduled_publish_at,
        message:
          dgettext_noop("errors", "Scheduled publish time is required for scheduled posts.")
      )
    else
      changeset
    end
  end

  defp lifecycle(changeset, _other_status), do: changeset
end
