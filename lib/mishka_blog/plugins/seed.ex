# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.Seed do
  @moduledoc """
  The blog's parts of the installer's checklist: a plugin on `installer:seed`
  (`MishkaCmsCore.Install.Seeds`).

  Subscribing is the whole declaration. The installer lists the blog's row with its two parts, and
  the host's seed scripts run them with every other plugin's. The blog's link (`/blog`) is declared
  once, on `MishkaBlog.Plugins.Installer`: the `pages` part's install adds it to the site's header
  menu the first time, and every dev site's `Dev` dropdown lists it. Priority 10 runs the blog
  before the documentation.

  | part | | installers |
  | --- | --- | --- |
  | `pages` | ticked at the start | dev, prod |
  | `samples` | ticked at the start | dev |

  Under its own key (`"mishka_blog"`) it appends one report to `reports`; any other key goes back
  untouched.

    * `pages` asks `MishkaCmsCore.Install.Extensions.install/4` for the blog, so
      `MishkaBlog.Plugins.Installer` writes the components, pages and permissions and the site is
      recorded as set up (`mishka_blog.installed`). A refusal is reported as `%{error: reason}`.
    * `samples` runs `MishkaBlog.Dev.Seeds.dev_seed/3` at `size: :normal` and
      `MishkaBlog.Dev.Seeds.stress_seed/2`, at its default volumes, at `size: :stress`.

  SAMPLE DATA NEVER REACHES A PRODUCTION BUILD. Core does not show or run a `:dev` part there, and a
  `samples` call that arrives anyway is answered with `%{error: :dev_in_production}` and writes
  nothing (`MishkaCmsCore.Install.Seeds.production_build?/0`).
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:seed",
    initial: %{
      priority: 10,
      extra: [
        %{
          id: "pages",
          label: gettext_noop("Blog pages and components"),
          summary: gettext_noop("The pages, components and permissions a site's blog runs on"),
          envs: [:dev, :prod],
          default: true
        },
        %{
          id: "samples",
          label: gettext_noop("Sample posts"),
          summary:
            gettext_noop("Multilingual posts, comments, bloggers and teams, with locked examples"),
          envs: [:dev],
          default: true
        }
      ]
    }

  alias MishkaBlog.Dev.Seeds, as: DevSeeds
  alias MishkaCmsCore.Install.{Extensions, Seeds}

  @key "mishka_blog"

  @impl true
  def call(%{key: @key, part: part, reports: reports} = payload) do
    new_payload = %{payload | reports: reports ++ [run(part, payload)]}
    {:reply, new_payload}
  end

  def call(payload), do: {:reply, payload}

  defp run("pages", %{site_id: site_id} = payload) do
    case Extensions.install(site_id, @key, Map.get(payload, :answers, %{})) do
      {:ok, report} -> report
      {:error, reason} -> %{error: reason}
    end
  end

  defp run("samples", payload) do
    if Seeds.production_build?(), do: %{error: :dev_in_production}, else: sample(payload)
  end

  defp run(part, _payload), do: %{error: {:unknown_part, part}}

  defp sample(%{size: :stress, site_id: site_id, users: users}),
    do: DevSeeds.stress_seed(site_id, users)

  defp sample(%{site_id: site_id, users: users, progress: progress}),
    do: DevSeeds.dev_seed(site_id, users, progress)
end
