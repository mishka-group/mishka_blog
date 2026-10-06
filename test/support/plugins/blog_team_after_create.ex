defmodule MishkaBlog.Test.Plugins.BlogTeamAfterCreate do
  @moduledoc """
  Test plugin for `blog:team:after_create` — reports the team id + meta to the
  `:__blog_hook_probe__` test process.
  """
  use MishkaInstaller.Event.Hook, event: "blog:team:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_team_after_create, record.id, meta})

    {:reply, record}
  end
end
