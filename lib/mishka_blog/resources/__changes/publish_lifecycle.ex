# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.PublishLifecycle do
  @moduledoc """
  Keeps a post's publish times in step with its `:status`.

  - A post whose status is `:published` loses its `:scheduled_publish_at`, in the same write, so
    the `scheduled_publish_future` check never refuses a later save once that time has passed. If it
    has no `:published_at`, it gets its scheduled time when that time has come (a scheduled post
    published by `MishkaBlog.Workers.PublishScheduledWorker`), else the current time, truncated
    to the second.
  - A post whose status is `:scheduled` and that has no `:scheduled_publish_at` is refused with an
    error on that field.
  - Any other status is left alone.

  On a create it applies to every post. On an update it applies only when the status is changing, so
  saving an already published post never moves its `:published_at`.

  ## The `blog:post:published` event

  A post that becomes `:published` — by `:publish`, `:master_publish`, a create or an update saving
  it as published, or `MishkaBlog.Workers.PublishScheduledWorker` at its scheduled time — fires
  `"blog:post:published"` once its write is committed, with `%{post: post, site_id: site_id,
  actor: actor | nil}`, so a plugin can share it elsewhere. Saving a post that was already published
  fires nothing.

  ## Usage

      create :create do
        change MishkaBlog.Resources.Changes.PublishLifecycle
      end

      update :update do
        change MishkaBlog.Resources.Changes.PublishLifecycle
      end

      update :publish do
        change set_attribute(:status, :published)
        change MishkaBlog.Resources.Changes.PublishLifecycle
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  @event "blog:post:published"

  @doc "The event a post that becomes published fires."
  @spec event() :: String.t()
  def event, do: @event

  @impl true
  def change(%{action_type: :update} = changeset, _opts, context) do
    status = Ash.Changeset.get_attribute(changeset, :status)

    if status == changeset.data.status,
      do: changeset,
      else: lifecycle(changeset, status, context)
  end

  def change(changeset, _opts, context) do
    lifecycle(changeset, Ash.Changeset.get_attribute(changeset, :status), context)
  end

  defp lifecycle(changeset, :published, context) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    changeset
    |> Ash.Changeset.after_transaction(&published(&1, &2, context.actor))
    |> Ash.Changeset.force_change_attribute(:scheduled_publish_at, nil)
    |> stamp_published_at(
      Ash.Changeset.get_attribute(changeset, :published_at),
      Ash.Changeset.get_attribute(changeset, :scheduled_publish_at),
      now
    )
  end

  defp lifecycle(changeset, :scheduled, _context) do
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

  defp lifecycle(changeset, _other_status, _context), do: changeset

  defp published(_changeset, {:ok, post} = result, actor) do
    MishkaInstaller.Event.Hook.call(@event, %{post: post, site_id: post.site_id, actor: actor},
      return: false
    )

    result
  end

  defp published(_changeset, error, _actor), do: error

  defp stamp_published_at(changeset, nil, %DateTime{} = scheduled_at, now) do
    case DateTime.compare(scheduled_at, now) do
      :gt -> Ash.Changeset.force_change_attribute(changeset, :published_at, now)
      _due -> Ash.Changeset.force_change_attribute(changeset, :published_at, scheduled_at)
    end
  end

  defp stamp_published_at(changeset, nil, nil, now),
    do: Ash.Changeset.force_change_attribute(changeset, :published_at, now)

  defp stamp_published_at(changeset, _published_at, _scheduled_at, _now), do: changeset
end
