defmodule MishkaBlogWeb.SidebarMenu do
  @moduledoc """
  The blog's admin pages and the one sidebar entry that links to them — a `"sidebar:menus"` plugin
  (`MishkaCmsCore.Sidebar`).

  Only `blog` is a link; it lands in the core's **Plugins** section. The core never names the blog,
  so removing this extension removes its entry and nothing in `MishkaCmsCore.Sidebar` changes.

  Each page reads its own gate from here, so the permission is written down once:

      on_mount {MishkaCmsCore.LiveUserAuth,
                {:require_permission, MishkaBlogWeb.SidebarMenu.permissions("blog.comments")}}

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "sidebar:menus", initial: %{priority: 40}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Item

  @editorial ["admin:dashboard:blog:post"]
  @moderation ["admin:dashboard:blog:comment"]
  @either @editorial ++ @moderation

  @items Enum.map(
           [
             %{
               extension: :mishka_blog,
               key: "blog",
               label: gettext_noop("Blog"),
               icon: "hero-book-open",
               path: "/admin/dashboard/blog",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Home.Index,
               group: "plugins",
               order: 10,
               permissions: @either,
               credit_name: "Mishka Blog",
               credit_url: "https://mishka.tools/cms/extensions/blog"
             },
             %{
               extension: :mishka_blog,
               key: "blog.posts",
               label: gettext_noop("Posts"),
               path: "/admin/dashboard/blog/posts",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Post.Index,
               nav: false,
               permissions: @editorial
             },
             %{
               extension: :mishka_blog,
               key: "blog.collections",
               label: gettext_noop("Collections"),
               path: "/admin/dashboard/blog/collections",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Collection.Index,
               nav: false,
               permissions: @editorial
             },
             %{
               extension: :mishka_blog,
               key: "blog.tags",
               label: gettext_noop("Tags"),
               path: "/admin/dashboard/blog/tags",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Tag.Index,
               nav: false,
               permissions: @editorial
             },
             %{
               extension: :mishka_blog,
               key: "blog.bloggers",
               label: gettext_noop("Bloggers"),
               path: "/admin/dashboard/blog/bloggers",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Blogger.Index,
               nav: false,
               permissions: @editorial
             },
             %{
               extension: :mishka_blog,
               key: "blog.comments",
               label: gettext_noop("Comments"),
               path: "/admin/dashboard/blog/comments",
               module: MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index,
               nav: false,
               permissions: @moderation
             }
           ],
           &Item.new!/1
         )

  @doc "This extension's sidebar entry plus every admin page it owns."
  @spec items() :: [Item.t()]
  def items, do: @items

  @doc "The permissions declared for one of this extension's pages. See `MishkaCmsCore.Sidebar.permissions/2`."
  @spec permissions(String.t()) :: [MishkaCmsCore.Accounts.Checks.AccessPermissions.requirement()]
  def permissions(key), do: Sidebar.permissions(@items, key)

  @impl true
  def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
end
