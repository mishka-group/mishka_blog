defmodule MishkaBlogWeb.Live.Admin.Dashboard.AutoPosting.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Auto Posting"))
      |> assign(:url_state, nil)
      |> subscribe_to_pubsub(socket.assigns.current_user)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaBlog.AutoPosting)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    for event <- ~w(created updated destroyed) do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "auto_posting:#{event}")
    end

    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    for event <- ~w(created updated destroyed) do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "auto_posting:#{site_id}:#{event}")
    end

    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "auto_posting" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "auto-postings-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
