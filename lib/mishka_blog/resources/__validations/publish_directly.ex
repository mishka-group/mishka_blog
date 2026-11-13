# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Validations.PublishDirectly do
  @moduledoc """
  Refuses a post's publish, or its schedule, by a blogger whose profile on the post's site does not
  have **Can Publish Directly** (`MishkaBlog.Blogger`'s `can_publish_directly`). Such a blogger saves
  the post as a draft, and an editor publishes it.

  It checks a write whose status becomes `:published` or `:scheduled`: the `:publish` and
  `:schedule` actions, their master twins, and a create or update saving the post as one of them.

  Not blocked:

    * a master (a user whose `site_id` is nil);
    * a user holding `admin:dashboard:blog:publish` or `admin:api:blog:publish`, or a wildcard
      covering it such as `admin:dashboard:blog:*`;
    * a user with no blogger profile on the site, an editor;
    * a write with no actor or with `authorize?: false`, such as
      `MishkaBlog.Workers.PublishScheduledWorker`.

  ## The `blog:post:can_publish` event

  The answer goes through the `"blog:post:can_publish"` mishka_installer event before it is kept,
  so a plugin may allow or refuse a publish by its own rule. A plugin is handed
  `%{allowed?: boolean, actor: user, site_id: id, blogger: blogger | nil, changeset: changeset}`
  and answers the same map, `allowed?` changed or not:

      use MishkaInstaller.Event.Hook, event: "blog:post:can_publish"

      def call(%{actor: actor} = data), do: {:reply, %{data | allowed?: reviewed?(actor)}}
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @event "blog:post:can_publish"
  @permissions ["admin:dashboard:blog:publish", "admin:api:blog:publish"]

  @doc "The event a publish is answered on."
  @spec event() :: String.t()
  def event, do: @event

  @impl true
  def validate(_changeset, _opts, %{authorize?: false}), do: :ok
  def validate(_changeset, _opts, %{actor: nil}), do: :ok

  def validate(changeset, _opts, %{actor: actor}) do
    case publishing?(changeset) do
      true -> answer(changeset, actor)
      false -> :ok
    end
  end

  defp publishing?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :status) and
      Ash.Changeset.get_attribute(changeset, :status) in [:published, :scheduled]
  end

  defp answer(changeset, actor) do
    site_id = site_id(changeset)
    blogger = blogger(actor, site_id)

    @event
    |> MishkaInstaller.Event.Hook.call(%{
      allowed?: allowed?(actor, blogger, changeset),
      actor: actor,
      site_id: site_id,
      blogger: blogger,
      changeset: changeset
    })
    |> refusal()
  end

  defp refusal(%{allowed?: false}) do
    {:error,
     field: :status,
     message:
       dgettext_noop(
         "errors",
         "Your blogger profile can't publish directly. Save the post as a draft for an editor to publish."
       )}
  end

  defp refusal(_allowed), do: :ok

  defp allowed?(%{site_id: nil}, _blogger, _changeset), do: true
  defp allowed?(_actor, nil, _changeset), do: true
  defp allowed?(_actor, %{can_publish_directly: true}, _changeset), do: true

  defp allowed?(actor, _blogger, changeset),
    do: AccessPermissions.match?(actor, changeset, permissions: @permissions)

  defp blogger(%{site_id: nil}, _site_id), do: nil
  defp blogger(_actor, nil), do: nil

  defp blogger(%{id: user_id}, site_id) do
    MishkaBlog.Blogger
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.select([:id, :can_publish_directly])
    |> Ash.read_one(tenant: site_id, authorize?: false)
    |> case do
      {:ok, blogger} -> blogger
      {:error, _error} -> nil
    end
  end

  defp site_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :site_id) || changeset.to_tenant || changeset.tenant
  end
end
