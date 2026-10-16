# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Notifiers.NotifySettings do
  @moduledoc """
  Registers mishka_blog's notification toggles with the Settings page through the `settings:register`
  mishka_installer hook. Each toggle is a boolean (default on) under the **Blog** tab (`category: "blog"`)
  in a **Notifications** group (`group:`), with `scope: :both` — a global default (shown in the master's
  Global view) that any site may override. Every mishka_blog setting lives under the Blog tab; `group`
  separates concerns within it (Notifications, and e.g. AI later).
  Delivery honours it: the engine gates every notification on
  `Settings.get(Notify.setting_key(type), true, site_id)` (site → global → default) before fanning it out.

  This is the whole "dynamic, admin-managed, grouped-by-extension" settings story — no bespoke
  registry, just a Settings definition per type. Registered in `MishkaBlog.Application`.

  See `MishkaCmsCore.Notify`, `MishkaCmsCore.Settings.define/3`, and `MishkaBlog.Notifiers.PostPublished`.
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 40}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.{Notify, Settings}

  @toggles [
    %{
      type: "blog:post:published",
      label: gettext_noop("Notify blog admins when a post is published"),
      description:
        gettext_noop("Sends an email to this site's blog admins each time a post goes live."),
      user_label: gettext_noop("New posts published")
    }
  ]

  @impl true
  def call(%{definitions: definitions} = data) do
    blog_definitions =
      Enum.flat_map(@toggles, fn toggle ->
        [
          Settings.define(Notify.setting_key(toggle.type), :boolean,
            default: true,
            category: "blog",
            group: gettext_noop("Notifications"),
            scope: :both,
            source: :plugin,
            label: toggle.label,
            description: toggle.description
          ),
          Notify.user_pref_definition(toggle.type, toggle.user_label)
        ]
      end)

    {:reply, %{data | definitions: definitions ++ blog_definitions}}
  end
end
