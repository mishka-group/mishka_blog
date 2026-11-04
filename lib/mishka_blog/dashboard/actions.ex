# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Actions do
  @moduledoc """
  The buttons an extension adds to the header of the blog dashboard, on the
  `"blog:dashboard:actions"` mishka_installer event, as a card is added to the settings page on
  `"account:security:cards"`. The blog adds none itself beyond its own, which the page draws.

  An action is `%{id: String.t(), label: String.t(), icon: String.t(), priority: integer()}` plus
  where it goes, one of:

    * `path: String.t()` — a link that navigates to that path of the admin;
    * `js: Phoenix.LiveView.JS.t()` — a button that runs that command when pressed, such as
      `JS.push("open_import", target: "#import-modal")`.

  Low `priority` comes first, before the blog's own buttons. An action with a missing field, an `id`
  already taken, or neither (or both) of `path` and `js` is dropped.

  A plugin is handed `%{actions: [], current_user: user}` and answers `{:reply, %{actions: actions}}`
  with its own added. It sees who is asking, so it may answer nothing for a user who may not use
  its button.

      use MishkaInstaller.Event.Hook, event: "blog:dashboard:actions"

      def call(%{actions: actions} = data) do
        action = %{id: "import", label: "Import", icon: "hero-arrow-down-tray", priority: 10, path: "/admin/dashboard/import"}
        {:reply, %{data | actions: actions ++ [action]}}
      end
  """

  @type t :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:icon) => String.t(),
          required(:priority) => integer(),
          optional(:path) => String.t(),
          optional(:js) => Phoenix.LiveView.JS.t()
        }

  @event "blog:dashboard:actions"

  @doc "The actions to draw for `user`, low priority first."
  @spec collect(map() | nil) :: [t()]
  def collect(user) do
    case MishkaInstaller.Event.Hook.call(@event, %{actions: [], current_user: user}) do
      %{actions: actions} when is_list(actions) ->
        actions
        |> Enum.filter(&action?/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  defp action?(%{id: id, label: label, icon: icon, priority: priority} = action)
       when is_binary(id) and is_binary(label) and is_binary(icon) and is_integer(priority),
       do: goes_somewhere?(action)

  defp action?(_other), do: false

  defp goes_somewhere?(%{path: path} = action) when is_binary(path),
    do: not is_map_key(action, :js)

  defp goes_somewhere?(%{js: %Phoenix.LiveView.JS{}} = action),
    do: not is_map_key(action, :path)

  defp goes_somewhere?(_action), do: false
end
