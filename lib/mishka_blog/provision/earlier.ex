# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Provision.Earlier do
  @moduledoc """
  The nine sample pages as `MishkaBlog.Provision` wrote them before the blog drew its pages in the
  site's own frame (the release whose kit is 3.9.0): each page carried a header of its own, with
  the blog's name, its links and the language letters, inside a `max-w-6xl` column, and the lists
  and the post had a sidebar beside them.

  They are held here the way `MishkaCmsCore.Install.StarterContent` holds the layout and the home
  page an earlier release wrote, because a page carries no fingerprint of what it was created from.
  `MishkaBlog.Provision` puts the new design on a page only when the template the page stores is
  one of these, character for character (`page_of/1`); a page that was edited anywhere is not, and
  is left as it is. The texts are frozen: a change to the pages the blog writes now is a change to
  `MishkaBlog.Provision`, never to this module, or a page that nobody edited would stop being
  recognised.
  """

  @blog "/:lang/blog"
  @category "#{@blog}/category"
  @tag "#{@blog}/tag"
  @categories "#{@blog}/categories"
  @tags "#{@blog}/tags"
  @author "#{@blog}/author"
  @team "#{@blog}/team"
  @people "#{@blog}/people"

  @post_path "#{@blog}/:slug"
  @category_path "#{@category}/:slug"
  @tag_path "#{@tag}/:slug"
  @author_path "#{@author}/:slug"
  @team_path "#{@team}/:slug"

  @paths [
    @blog,
    @post_path,
    @category_path,
    @tag_path,
    @categories,
    @tags,
    @author_path,
    @team_path,
    @people
  ]

  @doc """
  The template the earlier release wrote for the sample page whose default path is `path`, on a site
  named `site_name`; `nil` for any other path.
  """
  @spec template(String.t(), String.t()) :: String.t() | nil
  def template(@blog, site_name), do: blog_home(site_name)
  def template(@post_path, site_name), do: blog_post(site_name)
  def template(@category_path, site_name), do: blog_category(site_name)
  def template(@tag_path, site_name), do: blog_tag(site_name)
  def template(@categories, site_name), do: blog_categories(site_name)
  def template(@tags, site_name), do: blog_tags(site_name)
  def template(@author_path, site_name), do: blog_author(site_name)
  def template(@team_path, site_name), do: blog_team(site_name)
  def template(@people, site_name), do: blog_people(site_name)
  def template(_other, _site_name), do: nil

  @doc """
  The default path of the sample page `stored` is, when it is exactly what the earlier release wrote
  for one, and `nil` when it is anything else.

  The site's name is read off the template itself, where every `<.component>` names it, so a page of
  a site that was renamed since is still recognised; the comparison does not trim anything but the
  whitespace around the whole text, as `MishkaCmsCore.Runtime.PageSamples` compares a page with the
  one it ships.
  """
  @spec page_of(term()) :: String.t() | nil
  def page_of(stored) when is_binary(stored) do
    case Regex.run(~r/\ssite="([^"]*)"/, stored) do
      [_all, site_name] ->
        stored = String.trim(stored)

        Enum.find(@paths, &(String.trim(template(&1, site_name)) == stored))

      nil ->
        nil
    end
  end

  def page_of(_not_text), do: nil

  defp blog_home(site) do
    chrome(
      """
      <.component
        component_name="blog-featured-posts"
        site="#{site}"
        id="blog-featured"
        current_user={assigns[:current_user]}
        heading={t("Featured")}
        limit={3}
        show_excerpt={false}
        language={@page.language}
        post_base="#{@blog}"
      />

      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-posts"
        current_user={assigns[:current_user]}
        heading={t("Latest posts")}
        per_page={9}
        show_sort={true}
        show_total={true}
        language={@page.language}
        base={#{live_url(@blog)}}
        params={Map.drop(@query_params, ["lang"])}
        post_base="#{@blog}"
      />
      """,
      sidebar(site, :nothing)
    )
  end

  defp blog_post(site) do
    chrome(
      """
      <.component
        component_name="blog-post-detail"
        site="#{site}"
        id="blog-post"
        current_user={assigns[:current_user]}
        params={@query_params}
        post_param="slug"
        language={@page.language}
        post_base="#{@blog}"
        category_base="#{@category}"
        tag_base="#{@tag}"
      />

      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5 sm:p-7">
        <.component
          component_name="blog-post-comments"
          site="#{site}"
          id="blog-post-comments"
          params={@query_params}
          post_param="slug"
          language={@page.language}
          current_user={assigns[:current_user]}
        />
      </div>
      """,
      sidebar(site, :post)
    )
  end

  defp blog_category(site) do
    chrome(
      """
      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-category-posts"
        current_user={assigns[:current_user]}
        heading={t("Category")}
        per_page={9}
        show_total={true}
        language={@page.language}
        collection={@query_params["slug"]}
        base={#{live_url(@category, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        empty_text={t("Nothing is published in this category yet.")}
      />
      """,
      sidebar(site, :category)
    )
  end

  defp blog_tag(site) do
    chrome(
      """
      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-tag-posts"
        current_user={assigns[:current_user]}
        heading={t("Tag")}
        per_page={9}
        show_total={true}
        language={@page.language}
        tag={@query_params["slug"]}
        base={#{live_url(@tag, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        empty_text={t("Nothing is published under this tag yet.")}
      />
      """,
      sidebar(site, :tag)
    )
  end

  defp blog_categories(site) do
    chrome("""
    <.component
      component_name="blog-category-list"
      site="#{site}"
      id="blog-categories"
      current_user={assigns[:current_user]}
      heading={t("Categories")}
      variant="cards"
      parent="all"
      limit={60}
      show_count={true}
      show_description={true}
      language={@page.language}
      category_base="#{@category}"
      post_base="#{@blog}"
    />
    """)
  end

  defp blog_tags(site) do
    chrome("""
    <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5 sm:p-7">
      <.component
        component_name="blog-tag-cloud"
        site="#{site}"
        id="blog-tags"
        current_user={assigns[:current_user]}
        heading={t("Tags")}
        limit={100}
        show_count={true}
        language={@page.language}
        tag_base="#{@tag}"
      />
    </div>
    """)
  end

  defp blog_author(site) do
    chrome(
      """
      <.component
        component_name="blog-author-profile"
        site="#{site}"
        id="blog-author"
        current_user={assigns[:current_user]}
        slug={@query_params["slug"]}
        teams_text={t("Teams")}
        posts_heading={t("Posts")}
        per_page={9}
        language={@page.language}
        base={#{live_url(@author, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        team_base="#{@team}"
        missing_text={t("That blogger is not here, or no longer writes for this site.")}
        empty_text={t("Nothing published yet.")}
      />
      """,
      sidebar(site, :nothing)
    )
  end

  defp blog_team(site) do
    chrome(
      """
      <.component
        component_name="blog-team-profile"
        site="#{site}"
        id="blog-team"
        current_user={assigns[:current_user]}
        slug={@query_params["slug"]}
        members_heading={t("Members")}
        posts_heading={t("Posts")}
        per_page={9}
        language={@page.language}
        base={#{live_url(@team, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        author_base="#{@author}"
        missing_text={t("That team is not here, or is not active any more.")}
        members_empty_text={t("Nobody is in this team yet.")}
        empty_text={t("Nothing published yet.")}
      />
      """,
      sidebar(site, :nothing)
    )
  end

  defp blog_people(site) do
    chrome("""
    <.component
      component_name="blog-people"
      site="#{site}"
      id="blog-people"
      current_user={assigns[:current_user]}
      heading={t("People")}
      unteamed_heading={t("Writers")}
      language={@page.language}
      author_base="#{@author}"
      team_base="#{@team}"
      members_empty_text={t("Nobody is in this team yet.")}
      empty_text={t("Nobody writes here yet.")}
    />
    """)
  end

  defp sidebar(site, holds) do
    """
    <aside data-role="blog-sidebar" class="flex flex-col gap-5">
      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5">
        <.component
          component_name="blog-post-search"
          site="#{site}"
          id="blog-sidebar-search"
          current_user={assigns[:current_user]}
          heading={t("Search")}
          language={@page.language}
          post_base="#{@blog}"
        />
      </div>

      <.component
        component_name="blog-category-list"
        site="#{site}"
        id="blog-sidebar-categories"
        current_user={assigns[:current_user]}
        heading={t("Categories")}
        posts_per_category={3}
        show_count={true}
        language={@page.language}
        category_base="#{@category}"
        post_base="#{@blog}"#{marks(holds, :category, 4)}#{without_the_open_one(holds, 4)}
      />

      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5">
        <.component
          component_name="blog-tag-cloud"
          site="#{site}"
          id="blog-sidebar-tags"
          current_user={assigns[:current_user]}
          heading={t("Tags")}
          limit={24}
          show_count={true}
          language={@page.language}
          tag_base="#{@tag}"#{marks(holds, :tag, 6)}
        />
      </div>

      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-sidebar-recent"
        current_user={assigns[:current_user]}
        heading={t("Recent posts")}
        variant="compact"
        per_page={5}
        show_pager={false}
        show_excerpt={false}
        language={@page.language}
        post_base="#{@blog}"#{without_the_open_one(holds, 4)}
      />
    </aside>
    """
  end

  defp marks(holds, holds, pad), do: "\n#{String.duplicate(" ", pad)}params={@query_params}"
  defp marks(_elsewhere, _kind, _pad), do: ""

  defp without_the_open_one(:post, pad),
    do: ~s(\n#{String.duplicate(" ", pad)}exclude_slug={@query_params["slug"] || ""})

  defp without_the_open_one(_no_post_here, _pad), do: ""

  defp live_url(address, captured \\ nil)

  defp live_url(address, nil), do: ~s|site_path("#{address}", @page.language)|

  defp live_url(address, name) do
    captures =
      ~s|%{"lang" => @page.language, "#{name}" => @query_params["#{name}"]}|

    ~s|site_path("#{address}/:#{name}", #{captures})|
  end

  defp chrome(body, aside \\ nil) do
    """
    <div class="min-h-screen bg-[#f6f5f2] text-[#1b1a18]">
      <header class="border-b border-[#ecebe6] bg-white">
        <div class="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-6 py-5">
          <.link
            navigate={#{live_url(@blog)}}
            class="font-['Space_Grotesk'] text-[20px] font-bold tracking-[-0.01em]"
          >
            {t("Blog")}
          </.link>

          <nav class="flex flex-wrap items-center gap-2 text-[12.5px] font-semibold">
            <.link
              navigate={#{live_url(@categories)}}
              class="rounded-full border border-[#ecebe6] px-3 py-1.5 text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {t("Categories")}
            </.link>
            <.link
              navigate={#{live_url(@tags)}}
              class="rounded-full border border-[#ecebe6] px-3 py-1.5 text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {t("Tags")}
            </.link>
            <.link
              navigate={#{live_url(@people)}}
              class="rounded-full border border-[#ecebe6] px-3 py-1.5 text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {t("People")}
            </.link>

            <a
              :for={edition <- @page_languages}
              href={edition.path}
              hreflang={edition.language}
              class={[
                "rounded-full border px-3 py-1.5 uppercase",
                (edition.language == @page.language &&
                   "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
                  "border-[#ecebe6] text-[#6d6a63] hover:bg-[#f6f5f2]"
              ]}
            >
              {edition.language}
            </a>
          </nav>
        </div>
      </header>

      <main class="#{main_class(aside)}">
        <div class="flex flex-col gap-8">
    #{indent(body, 6)}
        </div>#{aside_block(aside)}
      </main>
    </div>
    """
  end

  defp main_class(nil), do: "mx-auto grid max-w-6xl grid-cols-1 gap-6 px-6 py-8"

  defp main_class(_aside),
    do: "mx-auto grid max-w-6xl grid-cols-1 gap-6 px-6 py-8 lg:grid-cols-[minmax(0,1fr)_320px]"

  defp aside_block(nil), do: ""
  defp aside_block(aside), do: "\n\n" <> indent(aside, 4)

  defp indent(markup, spaces) do
    pad = String.duplicate(" ", spaces)

    markup
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
