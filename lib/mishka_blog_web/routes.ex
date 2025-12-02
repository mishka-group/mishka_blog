defmodule MishkaBlogWeb.Routes do
  @moduledoc """
  Extension routes for MishkaBlog.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/blog", MishkaBlogWeb.Live.Admin.Dashboard.Home.Index, :index},
      {:live, "/blog/posts", MishkaBlogWeb.Live.Admin.Dashboard.Post.Index, :index}
    ]
  end

  def routes(:public), do: []
  def routes(:api), do: []
  def routes(_), do: []
end
