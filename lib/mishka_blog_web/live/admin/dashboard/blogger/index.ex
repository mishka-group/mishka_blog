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

  import MishkaBlogWeb.Live.Admin.Dashboard.VersionsModal, only: [close_modal: 2]

  alias MishkaBlog.Blogger
  alias MishkaBlogWeb.Live.Admin.Dashboard.VersionsModal
  alias MishkaCmsCoreWeb.Templates.CardChrome
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaGervaz.Table.Web.UrlSync

  @form_modal "blogger-form-modal"
  @versions_modal "blogger-versions-modal"
  @versions [
    resource: Blogger,
    name: :display_name,
    modal: @versions_modal,
    not_found: gettext_noop("Blogger not found or access denied")
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    new_socket =
      socket
      |> assign(:page_title, gettext("Bloggers"))
      |> assign(:url_state, nil)
      |> VersionsModal.assign_defaults()

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaBlog.Blogger)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_event("close_versions", _params, socket) do
    {:noreply, VersionsModal.reset(socket)}
  end

  def handle_event("versions_prev_page", _params, socket) do
    {:noreply, VersionsModal.previous_page(socket, @versions)}
  end

  def handle_event("versions_next_page", _params, socket) do
    {:noreply, VersionsModal.next_page(socket, @versions)}
  end

  def handle_event("toggle_version_preview", %{"version-id" => version_id}, socket) do
    {:noreply, VersionsModal.toggle_preview(socket, version_id)}
  end

  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    {:noreply, VersionsModal.restore(socket, @versions, version_id)}
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

  def handle_info({:row_action, "show_versions", %{"id" => record_id}}, socket) do
    {:noreply, VersionsModal.show(socket, @versions, record_id)}
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
  def handle_async(:load_versions, result, socket) do
    {:noreply, VersionsModal.loaded(socket, @versions, result)}
  end
end
