# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.TenantCrossSiteRefused do
  @moduledoc """
  Test plugin for `runtime:tenant:cross_site_refused` — reports what a refused write named to the
  `:__blog_hook_probe__` test process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:tenant:cross_site_refused"

  @impl true
  def call(refused, _meta) do
    if pid = Process.whereis(:__blog_hook_probe__),
      do: send(pid, {:cross_site_refused, refused})

    {:reply, refused}
  end
end
