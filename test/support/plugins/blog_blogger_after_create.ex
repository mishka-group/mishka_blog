defmodule MishkaBlog.Test.Plugins.BlogBloggerAfterCreate do
  @moduledoc """
  Test plugin for `blog:blogger:after_create` — reports the blogger id + meta to the
  `:__blog_hook_probe__` test process.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blogger:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_blogger_after_create, record.id, meta})

    {:reply, record}
  end
end
