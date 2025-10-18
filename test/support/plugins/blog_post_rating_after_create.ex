defmodule MishkaBlog.Test.Plugins.BlogPostRatingAfterCreate do
  @moduledoc """
  Test plugin for `blog:post_rating:after_create` — reports the rating id + meta to the
  `:__blog_hook_probe__` test process. PostRating is a global (non-tenant) interaction resource.
  """
  use MishkaInstaller.Event.Hook, event: "blog:post_rating:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_post_rating_after_create, record.id, meta})

    {:reply, record}
  end
end
