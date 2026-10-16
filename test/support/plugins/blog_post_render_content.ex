# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostRenderContent do
  @moduledoc """
  Test plugin for the content render filter `blog:blog_post:render_content` — appends a marker to the
  HTML to prove a plugin can transform `:rendered_content` (the WordPress `the_content` seam).
  """
  use MishkaInstaller.Event.Hook, event: "blog:blog_post:render_content"

  @impl true
  def call(%{html: html} = data, _meta) do
    {:reply, %{data | html: "#{html} [rendered by plugin]"}}
  end
end
