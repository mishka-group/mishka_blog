# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostQueryPublished do
  @moduledoc """
  Test plugin for the query filter `blog:blog_post:query_published` — reports to the test process that
  it received the `Ash.Query` (the WordPress `pre_get_posts` seam). It returns the query unchanged so
  it never disturbs other reads in the shared engine.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blog_post:query_published"

  @impl true
  def call(%Ash.Query{} = query, _meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:query_hook_fired, query.action.name})

    {:reply, query}
  end
end
