# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.ShareCardTargets do
  @moduledoc """
  A plain mishka_installer plugin: answers `MishkaCmsCore.Runtime.ShareCard.targets_event/0` with
  the blog's share cards on the site asked, under `"mishka_blog"` (`MishkaBlog.ShareCards.targets/1`),
  so a redraw of every card of a site — and the blog's own Redraw button in its check-and-repair
  modal — reaches its posts, categories, tags, bloggers and teams. Registered in
  `MishkaBlog.Application`.
  """
  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Runtime.ShareCard.targets_event(),
    initial: %{priority: 60}

  alias MishkaBlog.ShareCards
  alias MishkaCmsCore.Runtime.ShareCard

  @producer "mishka_blog"

  @doc ~s(The name the blog's targets are put under: `"#{@producer}"`.)
  @spec producer() :: String.t()
  def producer, do: @producer

  @impl true
  def call(%{site_id: site_id} = data),
    do: {:reply, ShareCard.put_targets(data, @producer, fn -> ShareCards.targets(site_id) end)}

  def call(data), do: {:reply, data}
end
