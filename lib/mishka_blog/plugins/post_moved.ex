# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostMoved do
  @moduledoc """
  Sends a post asked for at an address that is not its own to its own address with a 301, on the
  `runtime:page:moved` mishka_installer hook (`MishkaCmsCore.Runtime.Redirects.moved_event/0`), as
  WordPress's `redirect_canonical()` does. Core asks it only for an address no redirect rule names,
  at a page that shows posts (`MishkaBlog.Plugins.PageRecords` declares `"blog:post"` with
  `moves: true`).

  A post's own address is the one `MishkaBlog.Address.of/3` gives: the site's post page for its
  language (of the pages that show posts, the one with the highest priority), filled from the post,
  with its first category as `:category`. A request is sent there when:

    * the address names the post by a date, a number or a category it does not have
      (`MishkaBlog.Address.agrees?/2`): `/blog/apps/hello` for a post filed under `news` alone;
    * the post is asked for at a page of posts that is not its own: `/blog/hello` for a post filed
      under `news` on a site whose post page is `/:lang/blog/:category/:slug`.

  Another of the post's categories is its address too, as in WordPress: `/blog/apps/hello` for a
  post filed under `news` and `apps` is answered by the page, whose head names the first category's
  address as canonical (`MishkaBlog.Plugins.PageSeo`). A slug no published post has, and a post
  that has no address of its own (filed under nothing, on a site whose post page names
  `:category`), are not this plugin's: the page answers them as before.

  Nothing is read while the request can only be the post's own address: the site's post page for
  the language, and no date, number or category in it. Otherwise the post is read once, by its
  slug, as a guest.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "runtime:page:moved", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{Address, BlogPost, Collection}
  alias MishkaCmsCore.Runtime.Languages

  @impl true
  def call(nil, %{record: "blog:post", site_id: site_id, page: %{path: path}, params: params})
      when is_binary(site_id) and is_map(params) do
    language = Map.get(params, Languages.capture()) || Languages.primary(site_id)
    own_page? = Address.path(site_id, "blog:post", language) == {:ok, path}

    with %{"slug" => slug} when is_binary(slug) <- params,
         false <- own_page? and Map.take(params, Address.post_captures()) == %{},
         %BlogPost{} = post <- post(site_id, slug, language),
         false <- own_page? and Address.agrees?(post, params),
         to when is_binary(to) <- Address.of(post, site_id) do
      {:reply, {to, 301}}
    else
      _stays -> {:reply, nil}
    end
  end

  def call(answer, _meta), do: {:reply, answer}

  defp post(site_id, slug, language) do
    BlogPost
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(slug == ^slug and language == ^language)
    |> Ash.Query.select([:id, :slug, :language, :published_at, :number])
    |> Ash.Query.load(
      collections:
        Collection
        |> Ash.Query.select([:id, :slug])
        |> Ash.Query.sort(display_order: :asc, name: :asc)
    )
    |> Ash.read(page: [limit: 1])
    |> case do
      {:ok, %{results: [post | _rest]}} -> post
      _none -> nil
    end
  end
end
