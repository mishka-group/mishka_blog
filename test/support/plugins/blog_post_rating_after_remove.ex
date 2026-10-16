# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostRatingAfterRemove do
  @moduledoc """
  Test plugin for `blog:post_rating:after_remove` — proves the notifier fires on a DESTROY action
  (removing a rating) and reports the record id + meta to the `:__blog_hook_probe__` test process.
  """
  use MishkaInstaller.Event.Hook, event: "blog:post_rating:after_remove"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:blog_post_rating_after_remove, record.id, meta})

    {:reply, record}
  end
end
