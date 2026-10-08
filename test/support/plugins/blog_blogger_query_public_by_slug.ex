defmodule MishkaBlog.Test.Plugins.BlogBloggerQueryPublicBySlug do
  @moduledoc """
  Test plugin for the query filter `blog:blogger:query_public_by_slug` — reports to the test process
  that it received the `Ash.Query` a blogger's page reads its blogger with, and the actor it is read
  for. It returns the query unchanged so it never disturbs other reads in the shared engine.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blogger:query_public_by_slug"

  @impl true
  def call(%Ash.Query{} = query, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:query_hook_fired, query.action.name, meta[:actor]})

    {:reply, query}
  end
end
