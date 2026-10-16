# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogCommentAfterCreate do
  @moduledoc """
  Test plugin for the `blog:comment:after_create` event.

  Opts into the read-only `meta` context with `call/2` and reports the comment id + meta it received
  to the `:__blog_hook_probe__` test process, so a test can assert the Comment global hook actually
  dispatched to a registered plugin when the `:create` action ran.
  """
  use MishkaInstaller.Event.Hook, event: "blog:comment:after_create"

  @impl true
  def call(comment, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_comment_after_create, comment.id, meta})

    {:reply, comment}
  end
end
