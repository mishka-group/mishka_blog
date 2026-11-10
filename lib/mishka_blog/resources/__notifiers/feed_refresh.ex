# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Notifiers.FeedRefresh do
  @moduledoc """
  An Ash notifier that drops a site's kept feeds after a write to a post, a category, a tag or a
  blogger, so the next request builds them again (`MishkaBlog.Feeds.invalidate/1`).

  Notifiers run after the transaction commits, for every action of a resource that lists this,
  master twins and bulk actions included. The site is the record's `site_id`, not the changeset's
  tenant, since a master twin runs with none.
  """
  @behaviour Ash.Notifier

  alias MishkaBlog.Feeds

  @impl true
  def notify(%Ash.Notifier.Notification{data: %{site_id: site_id}}), do: Feeds.invalidate(site_id)
  def notify(_notification), do: :ok

  # Asking for the original data forces a load before the action, which makes it non-atomic; the
  # record in `data` carries the site.
  @impl true
  def requires_original_data?(_resource, _action), do: false
end
