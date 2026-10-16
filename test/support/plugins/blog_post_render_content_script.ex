# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostRenderContentScript do
  @moduledoc """
  Test plugin for `blog:blog_post:render_content` that appends markup a sanitizer must clean — a
  script beside a tagged element — to prove the HTML a plugin produced is scrubbed before a page
  draws it, while stored content is drawn as it was stored.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blog_post:render_content"

  @impl true
  def call(%{html: html} = data, _meta) do
    {:reply,
     %{data | html: html <> ~s|<script>plugin()</script><b data-probe="plugin">added</b>|}}
  end
end
