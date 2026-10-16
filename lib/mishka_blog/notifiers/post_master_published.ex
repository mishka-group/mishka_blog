# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Notifiers.PostMasterPublished do
  @moduledoc """
  The master half of `MishkaBlog.Notifiers.PostPublished`. A master publishes through
  `:master_publish`, which fires `blog:blog_post:after_master_publish` — not the tenant action's
  event — so without a plugin here a post a master published would tell nobody. It delivers exactly
  what a tenant publish delivers, to the same audience. Registered in `MishkaBlog.Application`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.event_name(MishkaBlog.BlogPost, :master_publish),
    initial: %{priority: 40}

  @impl true
  defdelegate call(post, meta), to: MishkaBlog.Notifiers.PostPublished
end
