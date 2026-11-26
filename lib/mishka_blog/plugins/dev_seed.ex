# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.DevSeed do
  @moduledoc """
  Adds the blog's sample data to the dev seeds: a plugin on `MishkaCmsCore.Dev.Seeds.event/0`.

  Subscribing is the whole declaration. The installer's dev step lists the blog under the label and
  summary below, the host's seed scripts run it with every other seed, and `nav` puts `/blog` in
  every dev site's `Dev` dropdown. Priority 10 seeds the blog before the documentation.

  Under its own key (`"mishka_blog"`) it runs `MishkaBlog.Dev.Seeds.dev_seed/3` for `size: :dev` and
  `MishkaBlog.Dev.Seeds.stress_seed/2`, at its default volumes, for `size: :stress`, and appends what
  the seed returned to `reports`. Any other key goes back untouched.

  DEV ONLY. `MishkaBlog.Application` supervises it only where the config sets `:env_dev?` or
  `:env_test?`, so a production build never registers it.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Dev.Seeds.event(),
    initial: %{
      priority: 10,
      extra: [
        %{
          label: gettext_noop("Mishka Blog"),
          summary:
            gettext_noop("Multilingual posts, comments, bloggers and teams, with locked examples"),
          nav: [%{label: "Blog", path: "/blog"}]
        }
      ]
    }

  alias MishkaBlog.Dev.Seeds

  @key "mishka_blog"

  @impl true
  def call(%{key: @key, reports: reports} = payload),
    do: {:reply, %{payload | reports: reports ++ [seed(payload)]}}

  def call(payload), do: {:reply, payload}

  defp seed(%{size: :dev, site_id: site_id, users: users, progress: progress}),
    do: Seeds.dev_seed(site_id, users, progress)

  defp seed(%{size: :stress, site_id: site_id, users: users}),
    do: Seeds.stress_seed(site_id, users)
end
