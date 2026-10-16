# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Blogger.Index do
  @moduledoc """
  The bloggers grid: a Gervaz table drawn as `MishkaBlogWeb.Templates.BloggerCard`, its create/edit
  form, and the version history of one blogger.

  The page itself is thin — it decodes the URL state, forwards PubSub broadcasts into the table
  component, and closes the form modal over the `gervaz:exec-js` bridge. The only feature it owns is
  the version history, which is read a page at a time off the render and shown in a modal beside the
  form's, the same way `MishkaBlogWeb.Live.Admin.Dashboard.Post.Index` shows a post's — the modal and
  its list are `MishkaCmsCoreWeb.Templates.VersionHistory`, shared across the admin.

  See `MishkaBlog.Blogger` for the table, filter and row-action definitions.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaBlog.Blogger
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCoreWeb.Templates.CardChrome
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaGervaz.Table.Web.UrlSync

  require Ash.Query

  @versions_per_page 10
  @form_modal "blogger-form-modal"
  @versions_modal "blogger-versions-modal"

  # A modal opened by `:if` snaps in and out — it is gone from the DOM before its own transition can
  # run. Both modals here stay rendered and are driven by the same `gervaz:exec-js` bridge the Gervaz
  # form uses, so they fade the way every other modal in the admin does.
  defp open_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.show_modal(id))

  defp close_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.hide_modal(id))

  defp exec_modal_js(socket, id, js) do
    push_event(socket, "gervaz:exec-js", %{target: id, js: Jason.encode!(js.ops)})
  end

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    new_socket =
      socket
      |> assign(:page_title, gettext("Bloggers"))
      |> assign(:url_state, nil)
      |> assign(:versions_blogger_id, nil)
      |> assign(:versions_blogger_name, nil)
      |> assign(:versions, [])
      |> assign(:version_masters, MapSet.new())
      |> assign(:versions_loading, false)
      |> assign(:preview_version_id, nil)
      |> assign(:versions_page, 1)
      |> assign(:versions_total, 0)
      |> assign(:versions_per_page, @versions_per_page)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaBlog.Blogger)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_event("close_versions", _params, socket) do
    {:noreply, reset_versions(socket)}
  end

  def handle_event("versions_prev_page", _params, socket) do
    page = socket.assigns.versions_page

    if page > 1 do
      {:noreply,
       socket
       |> assign(:versions_page, page - 1)
       |> assign(:preview_version_id, nil)
       |> load_versions()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("versions_next_page", _params, socket) do
    %{versions_page: page, versions_total: total, versions_per_page: per_page} = socket.assigns
    max_page = ceil(total / per_page)

    if page < max_page do
      {:noreply,
       socket
       |> assign(:versions_page, page + 1)
       |> assign(:preview_version_id, nil)
       |> load_versions()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_version_preview", %{"version-id" => version_id}, socket) do
    current = socket.assigns.preview_version_id
    new_preview_id = if current == version_id, do: nil, else: version_id
    {:noreply, assign(socket, :preview_version_id, new_preview_id)}
  end

  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    current_user = socket.assigns.current_user
    blogger_id = socket.assigns.versions_blogger_id

    result =
      case current_user do
        %User{site_id: nil} ->
          Blogger
          |> Ash.ActionInput.for_action(
            :master_restore_version_api,
            %{
              id: blogger_id,
              version_id: version_id
            },
            actor: current_user
          )
          |> Ash.run_action(actor: current_user)

        %User{site_id: site_id} when is_binary(site_id) ->
          Blogger
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: blogger_id, version_id: version_id},
            tenant: site_id
          )
          |> Ash.run_action(actor: current_user, tenant: site_id)
      end

    case result do
      {:ok, _blogger} ->
        {:noreply,
         socket
         |> close_modal(@versions_modal)
         |> reset_versions()
         |> put_flash(:info, gettext("Version restored successfully"))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, restore_error(error))}
    end
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_modal(@form_modal)
     |> put_flash(:info, gettext("Blogger created successfully"))}
  end

  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_modal(@form_modal)
     |> put_flash(:info, gettext("Blogger updated successfully"))}
  end

  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_modal(socket, @form_modal)}
  end

  def handle_info({:row_action, "show_versions", %{"id" => blogger_id}}, socket) do
    socket =
      socket
      |> assign(:versions_blogger_id, blogger_id)
      |> assign(:versions_blogger_name, nil)
      |> assign(:versions, [])
      |> assign(:versions_page, 1)
      |> assign(:versions_total, 0)
      |> assign(:preview_version_id, nil)
      |> open_modal(@versions_modal)
      |> load_versions()

    {:noreply, socket}
  end

  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "blogger" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "bloggers-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_versions, {:ok, {:ok, {blogger, versions, total, masters}}}, socket) do
    {:noreply,
     socket
     |> assign(:versions_blogger_name, blogger.display_name)
     |> assign(:versions, versions)
     |> assign(:version_masters, masters)
     |> assign(:versions_total, total)
     |> assign(:versions_loading, false)}
  end

  def handle_async(:load_versions, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:versions_loading, false)
     |> close_modal(@versions_modal)
     |> reset_versions()
     |> put_flash(:error, gettext("Blogger not found or access denied"))}
  end

  def handle_async(:load_versions, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:versions_loading, false)
     |> put_flash(:error, gettext("Failed to load versions"))}
  end

  def handle_async(:load_versions, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:versions_loading, false)
     |> put_flash(:error, gettext("Failed to load versions"))}
  end

  defp reset_versions(socket) do
    socket
    |> assign(:versions_blogger_id, nil)
    |> assign(:versions_blogger_name, nil)
    |> assign(:versions, [])
    |> assign(:versions_page, 1)
    |> assign(:versions_total, 0)
    |> assign(:preview_version_id, nil)
  end

  defp restore_error(error),
    do: MishkaGervaz.Errors.extract_error_message(error, MishkaBlog.Blogger)

  defp load_versions(socket) do
    %{
      current_user: current_user,
      versions_blogger_id: blogger_id,
      versions_page: page,
      versions_per_page: per_page
    } = socket.assigns

    offset = (page - 1) * per_page

    socket
    |> assign(:versions_loading, true)
    |> MishkaGervaz.Messages.start_async(:load_versions, fn ->
      # Built and run with the signed-in user: an action checks the user it was built with.
      {action, opts} =
        case current_user do
          %User{site_id: nil} ->
            {:master_get_with_versions, [actor: current_user]}

          %User{site_id: site_id} when is_binary(site_id) ->
            {:get_with_versions, [actor: current_user, tenant: site_id]}
        end

      blogger =
        Blogger
        |> Ash.Query.for_read(
          action,
          %{versions_limit: per_page, versions_offset: offset},
          opts
        )
        |> Ash.Query.filter(id: blogger_id)
        |> Ash.read_one(opts)

      case blogger do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, blogger} ->
          {:ok, total} =
            MishkaBlog.Blogger.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: current_user)
            |> Ash.Query.filter(version_source_id: blogger_id)
            |> Ash.count(actor: current_user)

          versions = blogger.sorted_versions || []
          {:ok, {blogger, versions, total, VersionHistory.master_ids(versions)}}

        {:error, _reason} = error ->
          error
      end
    end)
  end
end
