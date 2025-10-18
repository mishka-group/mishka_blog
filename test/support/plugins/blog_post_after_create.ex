defmodule MishkaBlog.Test.Plugins.BlogPostAfterCreate do
  @moduledoc """
  Test plugin for the `blog:blog_post:after_create` event.

  Opts into the read-only `meta` context with `call/2` and reports the post id + meta it received to
  the `:__blog_hook_probe__` test process, so a test can assert the BlogPost global hook actually
  dispatched to a registered plugin when the `:create` action ran.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blog_post:after_create"

  @impl true
  def call(post, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_post_after_create, post.id, meta})

    {:reply, post}
  end
end
