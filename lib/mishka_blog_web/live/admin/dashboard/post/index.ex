defmodule MishkaBlogWeb.Live.Admin.Dashboard.Post.Index do
  @moduledoc """
  The blog posts list: a Gervaz table drawn as `MishkaBlogWeb.Templates.PostCard`, its create/edit
  form, and the version history of one post.

  The page itself is thin — it decodes the URL state, forwards PubSub broadcasts into the table
  component, opens the form modal for a language chip, and closes it over the `gervaz:exec-js`
  bridge. The only feature it owns is the version history, which is read a page at a time off the
  render and shown in a modal beside the form's, the same way
  `MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index` shows a collection's.

  Restoring goes through the generic `:restore_version_api` / `:master_restore_version_api` actions
  rather than the `update` twins of the same name: `Ash.ActionInput.for_action/3` only accepts an
  action of type `:action`, and handed an update it raises rather than returning `{:error, _}`.

  See `MishkaBlog.BlogPost` for the table, filter and row-action definitions.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCoreWeb.Templates.CardChrome
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaGervaz.Table.Web.UrlSync

  require Ash.Query

  @versions_per_page 10
  @form_modal "blog-post-form-modal"
  @versions_modal "post-versions-modal"

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
      |> assign(:page_title, gettext("Blog Posts"))
      |> assign(:url_state, nil)
      |> assign(:versions_post_id, nil)
      |> assign(:versions_post_title, nil)
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
    url_state = UrlSync.decode(params, uri, MishkaBlog.BlogPost)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  # A language chip opens that edition in the form the row's Edit action opens, so a post has one
  # edit path whichever language you reached it by.
  @impl true
  def handle_event("show_edition", %{"id" => post_id}, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(BlogPost),
      record_id: post_id
    )

    {:noreply, open_modal(socket, @form_modal)}
  end

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

  # Gervaz syncs a table's filters to the URL under its `url_sync` prefix, so the comments page can
  # be opened already filtered by handing it `comments_filter_post_id` — no extra state to pass and
  # the reader can clear it from the Post filter like any other.
  def handle_event("show_post_comments", %{"id" => post_id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: path(socket, "/admin/dashboard/blog/comments?comments_filter_post_id=#{post_id}")
     )}
  end

  def handle_event("toggle_version_preview", %{"version-id" => version_id}, socket) do
    current = socket.assigns.preview_version_id
    new_preview_id = if current == version_id, do: nil, else: version_id
    {:noreply, assign(socket, :preview_version_id, new_preview_id)}
  end

  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    current_user = socket.assigns.current_user
    post_id = socket.assigns.versions_post_id

    result =
      case current_user do
        %User{site_id: nil} ->
          BlogPost
          |> Ash.ActionInput.for_action(
            :master_restore_version_api,
            %{
              id: post_id,
              version_id: version_id
            },
            actor: current_user
          )
          |> Ash.run_action(actor: current_user)

        %User{site_id: site_id} when is_binary(site_id) ->
          BlogPost
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: post_id, version_id: version_id},
            tenant: site_id
          )
          |> Ash.run_action(actor: current_user, tenant: site_id)
      end

    case result do
      {:ok, _post} ->
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
     |> put_flash(:info, gettext("Post created successfully"))}
  end

  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_modal(@form_modal)
     |> put_flash(:info, gettext("Post updated successfully"))}
  end

  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_modal(socket, @form_modal)}
  end

  def handle_info({:row_action, "show_versions", %{"id" => post_id}}, socket) do
    socket =
      socket
      |> assign(:versions_post_id, post_id)
      |> assign(:versions_post_title, nil)
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
          topic: "blog_post" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "posts-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_versions, {:ok, {:ok, {post, versions, total, masters}}}, socket) do
    {:noreply,
     socket
     |> assign(:versions_post_title, post.title)
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
     |> put_flash(:error, gettext("Post not found or access denied"))}
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
    |> assign(:versions_post_id, nil)
    |> assign(:versions_post_title, nil)
    |> assign(:versions, [])
    |> assign(:versions_page, 1)
    |> assign(:versions_total, 0)
    |> assign(:preview_version_id, nil)
  end

  defp restore_error(error),
    do: MishkaGervaz.Errors.extract_error_message(error, MishkaBlog.BlogPost)

  defp load_versions(socket) do
    %{
      current_user: current_user,
      versions_post_id: post_id,
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

      post =
        BlogPost
        |> Ash.Query.for_read(
          action,
          %{versions_limit: per_page, versions_offset: offset},
          opts
        )
        |> Ash.Query.filter(id: post_id)
        |> Ash.read_one(opts)

      case post do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, post} ->
          {:ok, total} =
            MishkaBlog.BlogPost.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: current_user)
            |> Ash.Query.filter(version_source_id: post_id)
            |> Ash.count(actor: current_user)

          versions = post.sorted_versions || []
          {:ok, {post, versions, total, VersionHistory.master_ids(versions)}}

        {:error, _reason} = error ->
          error
      end
    end)
  end
end
