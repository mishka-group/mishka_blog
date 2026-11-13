# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostPublishedProbe do
  @moduledoc """
  Test plugin on `blog:post:published`: reports the post id and site it is handed to the
  `:__blog_hook_probe__` test process.
  """
  use MishkaInstaller.Event.Hook, event: "blog:post:published"

  @impl true
  def call(%{post: post, site_id: site_id} = data) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_post_published, post.id, site_id})

    {:reply, data}
  end
end
