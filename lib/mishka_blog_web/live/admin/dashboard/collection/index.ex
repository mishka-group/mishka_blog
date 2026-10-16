# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.LanguageAccent
  alias MishkaCmsCoreWeb.Templates.CardChrome
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaGervaz.Table.Web.UrlSync
  require Ash.Query

  @versions_per_page 10

  @versions_modal "collection-versions-modal"
  @edition_modal "collection-edition-modal"

  defp close_form_modal(socket), do: close_modal(socket, "collection-form-modal")

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
      |> assign(:page_title, gettext("Collections"))
      |> assign(:url_state, nil)
      |> assign(:versions_collection_id, nil)
      |> assign(:versions_collection_name, nil)
      |> assign(:versions, [])
      |> assign(:version_masters, MapSet.new())
      |> assign(:versions_loading, false)
      |> assign(:preview_version_id, nil)
      |> assign(:versions_page, 1)
      |> assign(:versions_total, 0)
      |> assign(:versions_per_page, @versions_per_page)
      |> assign(:versions_editions, [])
      |> assign(:edition, nil)
      |> assign(:edition_loading, false)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaBlog.Collection)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_event("show_edition", %{"id" => collection_id}, socket) do
    {:noreply, show_edition(socket, collection_id)}
  end

  @impl true
  def handle_event("close_edition", _params, socket) do
    {:noreply, socket |> assign(:edition, nil) |> assign(:edition_loading, false)}
  end

  @impl true
  def handle_event("show_versions_for", %{"id" => collection_id}, socket) do
    {:noreply,
     socket
     |> assign(:versions_collection_id, collection_id)
     |> assign(:versions_page, 1)
     |> assign(:preview_version_id, nil)
     |> load_versions()}
  end

  @impl true
  def handle_event("close_versions", _params, socket) do
    {:noreply,
     socket
     |> assign(:versions_collection_id, nil)
     |> assign(:versions_collection_name, nil)
     |> assign(:versions, [])
     |> assign(:versions_page, 1)
     |> assign(:versions_total, 0)
     |> assign(:preview_version_id, nil)}
  end

  @impl true
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

  @impl true
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

  @impl true
  def handle_event("toggle_version_preview", %{"version-id" => version_id}, socket) do
    current = socket.assigns.preview_version_id
    new_preview_id = if current == version_id, do: nil, else: version_id
    {:noreply, assign(socket, :preview_version_id, new_preview_id)}
  end

  @impl true
  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    current_user = socket.assigns.current_user
    collection_id = socket.assigns.versions_collection_id

    result =
      case current_user do
        %User{site_id: nil} ->
          MishkaBlog.Collection
          |> Ash.ActionInput.for_action(
            :master_restore_version_api,
            %{
              id: collection_id,
              version_id: version_id
            },
            actor: current_user
          )
          |> Ash.run_action(actor: current_user)

        %User{site_id: site_id} when is_binary(site_id) ->
          MishkaBlog.Collection
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: collection_id, version_id: version_id},
            tenant: site_id
          )
          |> Ash.run_action(actor: current_user, tenant: site_id)
      end

    case result do
      {:ok, _collection} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Version restored successfully"))
         |> close_modal(@versions_modal)
         |> assign(:versions_collection_id, nil)
         |> assign(:versions_collection_name, nil)
         |> assign(:versions, [])}

      {:error, error} ->
        message = MishkaGervaz.Errors.extract_error_message(error, MishkaBlog.Collection)
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_open_form()
     |> put_flash(:info, gettext("Collection created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_open_form()
     |> put_flash(:info, gettext("Collection updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_open_form(socket)}
  end

  @impl true
  def handle_info({:row_action, "show_edition", %{"id" => collection_id}}, socket) do
    {:noreply, show_edition(socket, collection_id)}
  end

  @impl true
  def handle_info({:row_action, "show_versions", %{"id" => collection_id}}, socket) do
    socket =
      socket
      |> assign(:versions_collection_id, collection_id)
      |> assign(:versions_collection_name, nil)
      |> assign(:versions, [])
      |> assign(:versions_page, 1)
      |> assign(:versions_total, 0)
      |> assign(:preview_version_id, nil)
      |> open_modal(@versions_modal)
      |> load_versions()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "collection" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "collections-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  # Two modals host the same Gervaz form — the page's own "Add / Edit", and the one an edition chip
  # opens — and the form announces a save the same way from either. Whichever is open is the one to
  # close, and an edition being set is what says which that is.
  defp close_open_form(%{assigns: %{edition: edition}} = socket) when not is_nil(edition) do
    socket |> close_modal(@edition_modal) |> assign(:edition, nil)
  end

  defp close_open_form(socket), do: close_form_modal(socket)

  # Reached two ways — a language chip on the card, and the row's Edit action — and both want the same
  # modal over the same record, so neither owns the work.
  defp show_edition(socket, collection_id) do
    actor = socket.assigns.current_user

    socket
    |> assign(:edition, nil)
    |> assign(:edition_loading, true)
    |> open_modal(@edition_modal)
    |> MishkaGervaz.Messages.start_async(:load_edition, fn ->
      load_edition(actor, collection_id)
    end)
  end

  @impl true
  def handle_async(
        :load_versions,
        {:ok, {:ok, {collection, versions, total, masters, editions}}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:versions_collection_name, collection.name)
     |> assign(:versions, versions)
     |> assign(:version_masters, masters)
     |> assign(:versions_total, total)
     |> assign(:versions_editions, editions)
     |> assign(:versions_loading, false)}
  end

  def handle_async(:load_versions, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:versions_loading, false)
     |> assign(:versions_collection_id, nil)
     |> close_modal(@versions_modal)
     |> put_flash(:error, gettext("Collection not found or access denied"))}
  end

  def handle_async(:load_versions, {:ok, {:error, _}}, socket) do
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

  def handle_async(:load_edition, {:ok, {:ok, collection}}, socket) do
    {:noreply, socket |> assign(:edition, collection) |> assign(:edition_loading, false)}
  end

  def handle_async(:load_edition, _result, socket) do
    {:noreply,
     socket
     |> assign(:edition_loading, false)
     |> close_modal(@edition_modal)
     |> put_flash(:error, gettext("Collection not found or access denied"))}
  end

  # The edition is a sibling row the list itself never shows, so it is read on demand rather than
  # preloaded onto every card. A master reads it with tenancy bypassed, since a sibling may belong to
  # another site.
  defp load_edition(%User{site_id: nil} = actor, id) do
    MishkaBlog.Collection
    |> Ash.Query.for_read(:read_any, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:site, :post_count, :version_count])
    |> Ash.read_one(actor: actor)
    |> found()
  end

  defp load_edition(%User{site_id: site_id} = actor, id) when is_binary(site_id) do
    MishkaBlog.Collection
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: site_id)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:site, :post_count, :version_count])
    |> Ash.read_one(tenant: site_id, actor: actor)
    |> found()
  end

  defp load_edition(_actor, _id), do: {:error, :not_found}

  defp found({:ok, nil}), do: {:error, :not_found}
  defp found(result), do: result

  @doc """
  Every language edition of a collection, itself included, for the history modal's language row.

  The variants relationship is a self-join on `language_group_id`, so it already contains the record it
  was loaded from — which is what this row wants, since the point is to switch between siblings and see
  which one you are on. A collection with no group has only itself, and the row then has nothing to
  offer, so it renders as one chip rather than a switch.
  """
  @spec editions_of(map()) :: [map()]
  def editions_of(%{language_group_id: nil} = collection),
    do: [%{id: collection.id, language: to_string(collection.language)}]

  def editions_of(collection) do
    # Only one of the two relationships is ever loaded — which one depends on who is looking — and the
    # other arrives as `%Ash.NotLoaded{}`, which is truthy. So this takes the one that is a list.
    [:language_variants, :master_language_variants]
    |> Enum.find_value(fn key ->
      case Map.get(collection, key) do
        list when is_list(list) -> list
        _unloaded -> nil
      end
    end)
    |> case do
      nil ->
        [%{id: collection.id, language: to_string(collection.language)}]

      variants ->
        variants
        |> Enum.map(&%{id: &1.id, language: to_string(&1.language)})
        |> Enum.uniq_by(& &1.language)
        |> Enum.sort_by(& &1.language)
    end
  end

  defp load_versions(socket) do
    %{
      current_user: current_user,
      versions_collection_id: collection_id,
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

      variants =
        case current_user do
          %User{site_id: nil} -> :master_language_variants
          _tenant -> :language_variants
        end

      collection =
        MishkaBlog.Collection
        |> Ash.Query.for_read(
          action,
          %{versions_limit: per_page, versions_offset: offset},
          opts
        )
        |> Ash.Query.filter(id: collection_id)
        |> Ash.Query.load([variants])
        |> Ash.read_one(opts)

      case collection do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, collection} ->
          {:ok, total} =
            MishkaBlog.Collection.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: current_user)
            |> Ash.Query.filter(version_source_id: collection_id)
            |> Ash.count(actor: current_user)

          versions = collection.sorted_versions || []

          {:ok,
           {collection, versions, total, VersionHistory.master_ids(versions),
            editions_of(collection)}}

        {:error, _} = error ->
          error
      end
    end)
  end
end
