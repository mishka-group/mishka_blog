defmodule MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index do
  @moduledoc """
  The comments list: a Gervaz table drawn as `MishkaBlogWeb.Templates.CommentCard`, with a create /
  edit / reply form.

  The page decodes the URL state, forwards PubSub broadcasts into the table component, and drives the
  form modal over the `gervaz:exec-js` bridge. Replying is its own path: a row's Reply seeds the form
  with the parent comment's `parent_comment_id`, `post_id` and `site_id` and opens the modal, so the
  new comment is saved as a threaded answer — the same shape a document issue's reply takes.

  See `MishkaBlog.Comment` for the table, filter and row-action definitions.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaGervaz.Table.Web.UrlSync

  @form_modal "comment-form-modal"

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
      |> assign(:page_title, gettext("Comments"))
      |> assign(:url_state, nil)
      |> assign(:reply_defaults, nil)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaBlog.Comment)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  # Add opens the empty create form: a Reply closed with the modal's close icon leaves its parent's
  # ids behind, so they are dropped here before the form starts over.
  @impl true
  def handle_event("add_comment", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(MishkaBlog.Comment),
      record_id: nil,
      defaults: nil,
      reset: true
    )

    {:noreply, socket |> assign(:reply_defaults, nil) |> open_modal(@form_modal)}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "comment" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "comments-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  # Reply threads under the comment it answers: the parent's ids seed a fresh create form, and the
  # modal opens the same way Edit's does — Edit shows it from the row action's own `js`, but Reply has
  # to load the parent first, so the page opens it once the defaults are set.
  def handle_info({:row_action, "reply", %{"id" => comment_id}}, socket) do
    case get_comment(socket.assigns.current_user, comment_id) do
      {:ok, comment} when not is_nil(comment) ->
        defaults = %{
          parent_comment_id: comment.id,
          post_id: comment.post_id,
          site_id: comment.site_id
        }

        send_update(MishkaGervaz.Form.Web.Live,
          id: MishkaGervaz.Resource.Info.Form.component_id(MishkaBlog.Comment),
          record_id: nil,
          defaults: defaults,
          reset: true
        )

        {:noreply,
         socket
         |> assign(:reply_defaults, defaults)
         |> open_modal(@form_modal)}

      _not_found ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found"))}
    end
  end

  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_modal(@form_modal)
     |> assign(:reply_defaults, nil)
     |> put_flash(:info, gettext("Comment created successfully"))}
  end

  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_modal(@form_modal)
     |> put_flash(:info, gettext("Comment updated successfully"))}
  end

  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, socket |> close_modal(@form_modal) |> assign(:reply_defaults, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp get_comment(%User{site_id: nil} = user, id) do
    Ash.get(MishkaBlog.Comment, id, action: :master_get, actor: user)
  end

  defp get_comment(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    Ash.get(MishkaBlog.Comment, id, tenant: site_id, actor: user)
  end
end
