defmodule MishkaBlogWeb.Routes do
  @moduledoc """
  Extension routes for MishkaBlog.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/blog", MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, :index},
      {:live, "/blog/posts", MishkaBlogWeb.Live.Admin.Dashboard.Post.Index, :index},
      {:live, "/blog/collections", MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index, :index},
      {:live, "/blog/tags", MishkaBlogWeb.Live.Admin.Dashboard.Tag.Index, :index}
    ]
  end

  def routes(:public), do: []
  def routes(:api), do: []
  def routes(_), do: []
end
