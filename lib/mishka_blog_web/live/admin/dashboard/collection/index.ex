# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index do
  use MishkaCmsCore.ExtensionLiveView

  import MishkaBlogWeb.Live.Admin.Dashboard.VersionsModal, only: [open_modal: 2, close_modal: 2]

  alias MishkaBlogWeb.Live.Admin.Dashboard.VersionsModal
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.LanguageAccent
  alias MishkaCmsCoreWeb.Templates.CardChrome
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaGervaz.Table.Web.UrlSync

  require Ash.Query

  @versions_modal "collection-versions-modal"
  @edition_modal "collection-edition-modal"
  @versions [
    resource: MishkaBlog.Collection,
    name: :name,
    modal: @versions_modal,
    not_found: gettext_noop("Collection not found or access denied"),
    load: [master: [:master_language_variants], site: [:language_variants]],
    loaded: &__MODULE__.assign_editions/2
  ]

  defp close_form_modal(socket), do: close_modal(socket, "collection-form-modal")

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    new_socket =
      socket
      |> assign(:page_title, gettext("Collections"))
      |> assign(:url_state, nil)
      |> VersionsModal.assign_defaults()
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
     |> assign(:versions_record_id, collection_id)
     |> assign(:versions_page, 1)
     |> assign(:preview_version_id, nil)
     |> VersionsModal.load(@versions)}
  end

  @impl true
  def handle_event("close_versions", _params, socket) do
    {:noreply, VersionsModal.reset(socket)}
  end

  @impl true
  def handle_event("versions_prev_page", _params, socket) do
    {:noreply, VersionsModal.previous_page(socket, @versions)}
  end

  @impl true
  def handle_event("versions_next_page", _params, socket) do
    {:noreply, VersionsModal.next_page(socket, @versions)}
  end

  @impl true
  def handle_event("toggle_version_preview", %{"version-id" => version_id}, socket) do
    {:noreply, VersionsModal.toggle_preview(socket, version_id)}
  end

  @impl true
  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    {:noreply, VersionsModal.restore(socket, @versions, version_id)}
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
    {:noreply, VersionsModal.show(socket, @versions, collection_id)}
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
  def handle_async(:load_versions, result, socket) do
    {:noreply, VersionsModal.loaded(socket, @versions, result)}
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

  @doc false
  @spec assign_editions(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_editions(socket, collection),
    do: assign(socket, :versions_editions, editions_of(collection))

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
end
