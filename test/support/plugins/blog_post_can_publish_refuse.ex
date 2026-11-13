# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogPostCanPublishRefuse do
  @moduledoc "Test plugin on `blog:post:can_publish`: refuses every publish, a master's too."
  use MishkaInstaller.Event.Hook, event: "blog:post:can_publish"

  @impl true
  def call(data), do: {:reply, %{data | allowed?: false}}
end
