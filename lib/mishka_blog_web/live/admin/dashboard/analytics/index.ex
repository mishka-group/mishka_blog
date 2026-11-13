# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index do
  @moduledoc """
  The blog analytics page: KPI tiles; a views chart with Total, By category and Publishing tabs; a
  Top card with Bloggers, Categories, Tags, Teams and Commenters tabs; post age and weekday charts;
  comments over time and by status; and three post tables — every figure read from the daily view
  counts (`MishkaBlog.PostViewDaily`) and the comments by `MishkaBlog.Dashboard.Analytics`.

  The page shows only what is counted. There is no average read time, no bounce rate and no
  referrer here because nothing observes a reader leaving a post or keeps where they came from, and
  a tile that cannot be measured is worse than a tile that is missing. Unique Readers says it is
  approximate: each node of a site tells its readers apart on its own.

  ## The URL

  The period (7, 30 or 90 days), the Category, Tag, Blogger and Team filters, "Compare with previous
  period" and the Top Posts sort all live in the URL (`handle_params/3`), so a reload or a shared link
  opens the same view. The range buttons and the sort headers are patch links; a filter is gervaz's
  search select, whose pick patches the URL, its options read a page at a time, searched as they are
  typed (`MishkaBlog.Dashboard.Analytics.choices/3`).

  ## Loading

  The panels and the filters are lists (`MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Panels`), handed
  to the `blog:analytics:panels` and `blog:analytics:filters` plugins when the page opens. The page
  draws first, every card as a skeleton, then each data its tabs name is read once in its own
  `start_async/3` (`MishkaBlog.Dashboard.Analytics.load/5`) and drawn when it lands, the hidden tabs'
  too, so switching a tab (on the client) never waits. A
  changed period starts them all again; a result is only assigned while its period is still the one
  shown, so clicking through quickly cannot land an older read on top of a newer one. A new sort
  only reorders the posts already read.

  The page is a holder's of the blog's `admin:dashboard:blog:post` (`MishkaBlogWeb.SidebarMenu`).
  Every comment figure — the Engagement tile, the comments chart and card, the Commenters tab, a
  blogger's comments and a post's comments and engagement — is drawn only for a viewer who also
  holds `admin:dashboard:blog:comment`, and is not read for any other.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Logger

  alias MishkaBlog.Dashboard.Analytics
  alias MishkaBlog.Dashboard.Overview
  alias MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Panels
  alias MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, as: Home

  @sorts [:views, :readers, :comments, :engagement, :change]
  @closed_picker %{
    open?: false,
    search: "",
    options: [],
    more?: false,
    loading?: false,
    picked: nil
  }
  @panels_event "blog:analytics:panels"
  @filters_event "blog:analytics:filters"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    areas = Overview.areas(user)
    filters = asked(@filters_event, :filters, Panels.filters(), user)

    socket =
      socket
      |> assign(page_title: gettext("Blog Analytics"), period: nil, sort: :views, data: %{})
      |> assign(blog_areas: areas, filters: filters)
      |> assign(
        :panels,
        @panels_event |> asked(:panels, Panels.built_in(), user) |> Panels.visible(areas)
      )
      |> assign(:pickers, Map.new(filters, &{&1.id, @closed_picker}))

    {:ok, socket}
  end

  @doc "The event the page's panels are handed to when it opens."
  @spec panels_event() :: String.t()
  def panels_event, do: @panels_event

  @doc "The event the page's filters are handed to when it opens."
  @spec filters_event() :: String.t()
  def filters_event, do: @filters_event

  # A plugin answers the map it was handed, its list changed or not; anything else keeps the list.
  defp asked(event, key, list, user) do
    case MishkaInstaller.Event.Hook.call(event, %{key => list, current_user: user}) do
      %{^key => list} when is_list(list) -> list
      _other -> list
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = Analytics.period(params, Enum.map(socket.assigns.filters, & &1.id))
    sort = Enum.find(@sorts, :views, &(to_string(&1) == params["sort"]))
    socket = assign(socket, :sort, sort)

    socket =
      case period == socket.assigns.period do
        true -> socket
        false -> socket |> load_panels(period) |> label_picked(period)
      end

    {:noreply, socket}
  end

  # The four filters are gervaz's search select (`search_select/1` of the blog's gervaz UI adapter),
  # whose events — `relation_*` — come to this page: their options are read a page at a time, off the
  # render, as they are opened, searched and scrolled.
  @impl true
  def handle_event("relation_focus", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      socket = socket |> close_others(kind) |> put_picker(kind, %{picker | open?: true})

      case picker.options == [] and not picker.loading? do
        true -> load_choices(socket, kind, picker.search, 0)
        false -> socket
      end
    end)
  end

  def handle_event("relation_search", %{"filter" => name} = params, socket) do
    with_picker(socket, name, fn kind, picker ->
      term = String.trim(params["value"] || "")
      term = (String.length(term) >= 2 && term) || ""

      socket = close_others(socket, kind)

      case term == picker.search and picker.options != [] do
        true -> put_picker(socket, kind, %{picker | open?: true})
        false -> load_choices(socket, kind, term, 0)
      end
    end)
  end

  def handle_event("relation_load_more", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      load_choices(socket, kind, picker.search, length(picker.options))
    end)
  end

  def handle_event("relation_select", %{"filter" => name, "id" => id} = params, socket) do
    with_picker(socket, name, fn kind, picker ->
      period = socket.assigns.period
      period = %{period | filters: Map.put(period.filters, kind, id)}

      socket
      |> put_picker(kind, %{
        picker
        | open?: false,
          search: "",
          options: [],
          picked: {params["label"] || id, id}
      })
      |> push_patch(to: Panels.page_path(socket, period, socket.assigns.sort))
    end)
  end

  def handle_event("relation_close_dropdown", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, picker ->
      put_picker(socket, kind, %{picker | open?: false})
    end)
  end

  def handle_event("clear_filter", %{"filter" => name}, socket) do
    with_picker(socket, name, fn kind, _picker ->
      period = socket.assigns.period
      period = %{period | filters: Map.delete(period.filters, kind)}

      push_patch(socket, to: Panels.page_path(socket, period, socket.assigns.sort))
    end)
  end

  def handle_event("compare", params, socket) do
    period = %{socket.assigns.period | compare: params["compare"] == "true"}

    {:noreply, push_patch(socket, to: Panels.page_path(socket, period, socket.assigns.sort))}
  end

  @impl true
  def handle_async({:data, id}, {:ok, {period, data}}, socket) do
    socket =
      (period == socket.assigns.period &&
         assign(socket, :data, Map.put(socket.assigns.data, id, data))) || socket

    {:noreply, socket}
  end

  def handle_async({:choices, kind, term, offset}, {:ok, {options, more?}}, socket) do
    picker = socket.assigns.pickers[kind]

    socket =
      case picker.search == term do
        true ->
          options = (offset == 0 && options) || picker.options ++ options
          put_picker(socket, kind, %{picker | options: options, more?: more?, loading?: false})

        false ->
          socket
      end

    {:noreply, socket}
  end

  def handle_async({:picked, kind, id}, {:ok, {options, _more?}}, socket) do
    picker = socket.assigns.pickers[kind]

    socket =
      case {socket.assigns.period.filters[kind], options} do
        {^id, [{label, ^id}]} -> put_picker(socket, kind, %{picker | picked: {label, id}})
        _gone -> socket
      end

    {:noreply, socket}
  end

  def handle_async(name, {:exit, reason}, socket) do
    Logger.error("blog analytics #{inspect(name)} failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  @doc """
  The assigns of the `kind` filter's search select, as gervaz's `search_select/1` takes them:
  `picker` is the page's state of that filter, and `value` the value the URL picked.
  """
  @spec picker_assigns(String.t(), map(), String.t() | nil) :: map()
  def picker_assigns(kind, picker, value) do
    %{
      __changed__: nil,
      id: "analytics-filter-#{kind}",
      name: "filters[#{kind}]",
      filter_name: kind,
      table_id: "analytics",
      options: picker.options,
      value: value || "",
      selected_options: (picker.picked && value && [picker.picked]) || [],
      placeholder: gettext("All"),
      icon: "hero-magnifying-glass",
      search: true,
      has_more?: picker.more?,
      loading?: picker.loading?,
      dropdown_open?: picker.open?,
      search_term: picker.search,
      min_chars: 2,
      debounce: 300
    }
  end

  @doc "The search select of the blog's gervaz UI adapter, drawn from `picker_assigns/3`."
  @spec search_select(map()) :: Phoenix.LiveView.Rendered.t()
  def search_select(assigns),
    do: MishkaGervaz.Domain.Info.Table.ui_adapter(MishkaBlog).search_select(assigns)

  defp with_picker(socket, name, fun) do
    case socket.assigns.pickers do
      %{^name => picker} -> {:noreply, fun.(name, picker)}
      _unknown -> {:noreply, socket}
    end
  end

  defp choices(socket, kind, opts) do
    user = socket.assigns.current_user
    {module, function, args} = Enum.find(socket.assigns.filters, &(&1.id == kind)).choices

    fn -> apply(module, function, args ++ [user, opts]) end
  end

  # One list is open at a time: opening one shuts the others, whatever reached them first.
  defp close_others(socket, kind) do
    pickers =
      Map.new(socket.assigns.pickers, fn
        {^kind, picker} -> {kind, picker}
        {other, picker} -> {other, %{picker | open?: false}}
      end)

    assign(socket, :pickers, pickers)
  end

  defp put_picker(socket, kind, picker),
    do: assign(socket, :pickers, Map.put(socket.assigns.pickers, kind, picker))

  defp load_choices(socket, kind, term, offset) do
    picker = socket.assigns.pickers[kind]
    picker = %{picker | search: term, loading?: true, open?: true}
    picker = (offset == 0 && %{picker | options: []}) || picker

    socket
    |> put_picker(kind, picker)
    |> MishkaGervaz.Messages.start_async(
      {:choices, kind, term, offset},
      choices(socket, kind, search: term, offset: offset)
    )
  end

  # A filter the URL names is labelled off the render, as the list it was picked from labels it.
  defp label_picked(socket, period) do
    Enum.reduce(socket.assigns.filters, socket, fn %{id: kind}, socket ->
      label_one(socket, kind, period.filters[kind], socket.assigns.pickers[kind])
    end)
  end

  defp label_one(socket, kind, nil, picker), do: put_picker(socket, kind, %{picker | picked: nil})
  defp label_one(socket, _kind, id, %{picked: {_label, id}}), do: socket

  defp label_one(socket, kind, id, _picker) do
    (connected?(socket) &&
       MishkaGervaz.Messages.start_async(
         socket,
         {:picked, kind, id},
         choices(socket, kind, id: id)
       )) ||
      socket
  end

  # Every data the drawn tabs name is read once, in its own task, off the render.
  defp load_panels(socket, period) do
    socket = assign(socket, period: period, data: %{})

    case connected?(socket) do
      true ->
        socket.assigns.panels
        |> Enum.flat_map(& &1.tabs)
        |> Enum.uniq_by(& &1.data)
        |> Enum.reduce(socket, &start_data(&2, &1, period))

      false ->
        socket
    end
  end

  defp start_data(socket, %{data: id, load: load}, period) do
    user = socket.assigns.current_user
    comments? = Home.holds?(socket.assigns.blog_areas, [:comment])

    MishkaGervaz.Messages.start_async(socket, {:data, id}, fn ->
      {period, Analytics.load(id, load, user, period, comments?)}
    end)
  end
end
