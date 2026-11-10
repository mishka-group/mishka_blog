# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.FeedController do
  @moduledoc """
  The blog's feeds, in RSS 2.0, Atom 1.0 and JSON Feed 1.1, at the addresses
  `MishkaBlog.Feeds.path/4` writes: `/feed`, `/feed/atom`, `/feed.json`, and the feed of a term at
  `/feed/:kind/:key`, each also under a language, `/fa/feed`. What goes in them, and how they are
  built and kept, is described there.

  Routed through `MishkaBlogWeb.Routes.routes(:api)`, so the site is the one the request's host
  resolved to (`conn.assigns.current_site`), a site with the blog switched off never reaches this
  (`MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug`), and the feed is only ever of its rows. The
  format is the route's own (`private: %{feed_format: format}`), and the route answers whatever
  `Accept` a reader sends. A feed without a language prefix is in the site's primary language, and
  one under a prefix must be a language the site has.

  ## Caching

  A feed is sent with the content hash `ETag` and `last-modified` it was built with, as
  `public, max-age=300`, and no session cookie. A request whose `if-none-match` names the `ETag`, or
  `*`, is answered `304` with no body. The content type is `application/rss+xml`,
  `application/atom+xml` or `application/feed+json`, `charset=utf-8`, and `x-robots-tag: noindex`
  keeps a feed out of search results.

  ## Refusals

  A site whose feeds are off, a language the site does not have, a kind or key that is not a
  plausible address, and a term the site does not have are a `404` that no cache keeps, with a
  `text/plain` body of "Not Found". A nested term is reached by its whole chain,
  `/feed/category/design/accessibility`, or by its last segment alone.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn

  alias MishkaBlog.Feeds
  alias MishkaCmsCore.Runtime.Languages

  @max_age 300
  @max_key 255

  def show(
        %{assigns: %{current_site: %{} = site}, private: %{feed_format: format}} = conn,
        params
      ) do
    with {:ok, language} <- language(site, params),
         {:ok, scope, format} <- scope(params, format),
         {:ok, document} <- Feeds.fetch(site, scope, language, format) do
      answer(conn, document)
    else
      _refused -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp language(site, %{"lang" => language}) do
    if language in Languages.site(site.id), do: {:ok, language}, else: :error
  end

  defp language(site, _params), do: {:ok, Languages.primary(site.id)}

  # A nested term's whole chain, `design/accessibility`, is the term its last segment names, and
  # `atom` or `json` after at least two segments is the format, as it is after one key.
  defp scope(%{"kind" => kind, "chain" => [_parent, _leaf | _] = chain}, format) do
    case Enum.reverse(chain) do
      [suffix, key, _parent | _] when suffix in ["atom", "json"] ->
        scope(%{"kind" => kind, "key" => key}, String.to_existing_atom(suffix))

      [key | _] ->
        scope(%{"kind" => kind, "key" => key}, format)
    end
  end

  defp scope(%{"kind" => kind, "key" => key}, format) when is_binary(kind) and is_binary(key) do
    if kind in Feeds.kinds() and key != "" and byte_size(key) <= @max_key and String.valid?(key),
      do: {:ok, {kind, key}, format},
      else: :error
  end

  defp scope(_params, format), do: {:ok, :site, format}

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp answer(conn, document) do
    conn =
      conn
      |> put_resp_header("etag", document.etag)
      |> put_resp_header("last-modified", document.last_modified)
      |> put_resp_header("x-robots-tag", "noindex")
      |> put_resp_header("cache-control", "public, max-age=#{@max_age}")

    if unchanged?(conn, document.etag),
      do: conn |> send_resp(304, "") |> halt(),
      else:
        conn
        |> put_resp_content_type(document.content_type, "utf-8")
        |> send_resp(200, document.body)
  end

  defp unchanged?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == "*" or weak(&1) == weak(etag)))
  end

  defp weak("W/" <> tag), do: tag
  defp weak(tag), do: tag

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
