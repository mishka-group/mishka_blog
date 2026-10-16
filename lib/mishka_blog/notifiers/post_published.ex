# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Notifiers.PostPublished do
  @moduledoc """
  A plain mishka_installer plugin: when a tenant publishes a blog post
  (`blog:blog_post:after_publish`), notify the tenant's blog admins AND master admins — in one
  `Notify.deliver/3` call — except the publisher themselves (the notifier's `meta.actor`, passed as
  `except:`), so no one is told about their own post.

    * `{:permission, perms, site_id}` — tenant blog admins on the post's site (scoped reads).
    * `{:permission_masters, perms}` — master admins, who read unscoped and see every site's posts.

  `perms` is the blog's post area on the dashboard, `admin:dashboard:blog:post`, so its holders are
  told, and so is anyone holding a wildcard that covers it (`admin:dashboard:blog:*`, `admin:dashboard:*`, `admin:*`, `*`). A master publishes through
  `:master_publish`, which fires its own event: `MishkaBlog.Notifiers.PostMasterPublished` listens
  there and delivers through `call/2` here. Both are registered in `MishkaBlog.Application`; the
  per-site on/off toggle is registered by `MishkaBlog.Notifiers.NotifySettings`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.event_name(MishkaBlog.BlogPost, :publish),
    initial: %{priority: 40}

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Notify

  @impl true
  def call(post, meta) do
    actor = actor(meta)
    audience = ["admin:dashboard:blog:post"]

    Notify.deliver(
      %{
        type: "blog:post:published",
        title: gettext_noop("New post published"),
        body: to_string(post.title),
        icon: "hero-newspaper",
        link: "/admin/dashboard/blog/posts",
        source: "mishka_blog",
        metadata: %{"title" => to_string(post.title), "slug" => to_string(post.slug)}
      },
      tenant_permissions: audience,
      master_permissions: audience,
      site_id: post.site_id,
      actor: actor,
      except: actor && actor.id
    )

    {:reply, post}
  end

  # The publisher (the notifier's `meta.actor`) is skipped so they aren't told about their own post.
  defp actor(%{actor: %{} = actor}), do: actor
  defp actor(_), do: nil
end
