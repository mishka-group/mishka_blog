# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostViewedProbe do
  @moduledoc """
  Test plugin on `blog:post:viewed`: reports the batch it is handed to the `:__blog_hook_probe__`
  test process.
  """
  use MishkaInstaller.Event.Hook, event: "blog:post:viewed"

  @impl true
  def call(%{views: views} = data) do
    if pid = Process.whereis(:__blog_hook_probe__), do: send(pid, {:blog_post_viewed, views})
    {:reply, data}
  end
end
