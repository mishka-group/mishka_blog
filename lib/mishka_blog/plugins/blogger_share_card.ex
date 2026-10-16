# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.BloggerShareCard do
  @moduledoc """
  A plain mishka_installer plugin: after a blogger is saved (`blog:blogger:after_save` — created, updated or
  published, a master's twin alike), its share card is looked at in the background and drawn when
  what it shows changed (`MishkaCmsCore.Runtime.ShareCard.refresh/3`), so it is ready before the
  first visitor. Only while it is not archived (`MishkaBlog.ShareCards.target/1`). Registered in
  `MishkaBlog.Application`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaBlog.Blogger),
    initial: %{priority: 60}

  alias MishkaBlog.ShareCards
  alias MishkaCmsCore.Runtime.ShareCard

  @impl true
  def call(record, _meta) do
    with site_id when is_binary(site_id) <- record.site_id,
         {:record, _kind, _captures} = target <- ShareCards.target(record) do
      ShareCard.refresh(site_id, target)
    end

    {:reply, record}
  end
end
