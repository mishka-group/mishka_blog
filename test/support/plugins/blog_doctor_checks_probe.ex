# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogDoctorChecksProbe do
  @moduledoc """
  Test plugin on `doctor:checks`: answers the blog's check and repair window (`app: :mishka_blog`)
  with one check, "Probe check", that holders of `admin:dashboard:blog:comment` may see and that
  always passes. The window of any other extension is left as it came.
  """
  use MishkaInstaller.Event.Hook, event: "doctor:checks"

  @doc "The area a holder needs to be shown the probe's check."
  @spec permission() :: String.t()
  def permission, do: "admin:dashboard:blog:comment"

  @impl true
  def call(%{app: :mishka_blog, checks: checks} = data) do
    check = %{
      id: "probe",
      label: "Probe check",
      permission: permission(),
      group: "Probe",
      group_id: "probe",
      run: fn _site_id, _actor -> :ok end
    }

    {:reply, %{data | checks: checks ++ [check]}}
  end

  def call(data), do: {:reply, data}
end
