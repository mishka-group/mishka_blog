# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PostBookmark do
  @moduledoc """
  Manages user bookmarks for blog posts.

  This resource represents bookmarks that users create to save blog posts for later reading.
  Each bookmark links a user to a specific blog post, creating a personal reading list.

  The resource provides a simple interface for users to manage their reading lists
  without requiring administrative privileges. The unique constraint on user_id and
  post_id ensures each user can only bookmark a specific post once.

  This resource has no multitenancy of its own, so a bookmark may only name a post of the site
  it is made for — see `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`.
  Database-level constraints ensure data integrity and provide efficient querying for a user's
  bookmarked posts with pagination support.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  require Ash.Query
  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for post_bookmarks storage with indexing
  postgres do
    table "mishka_blog_post_bookmarks"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:user_id]
      index [:inserted_at]
    end

    references do
      reference :post, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "post_bookmark"

    includes [:post, :user]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:post_id, :user_id]

    create :create do
      description "Creates a bookmark for a blog post"
      primary? true
      accept [:post_id]
      upsert? true
      upsert_identity :unique_user_post_bookmark

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}

      # A post its actor may not open takes nothing from them, as though it were not there.
      validate {MishkaBlog.Resources.Validations.OpenToActor,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                lock: :effective_permissions,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}

      change relate_actor(:user, allow_nil?: true)
    end

    read :my_bookmarks do
      description "Reads all bookmarks for a specific user with pagination"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        if actor = context.actor do
          query
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.Query.filter(post.status == :published)
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    destroy :remove do
      description "Removes a bookmark"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own bookmarks
  policies do
    # Require actor for my_bookmarks action
    bypass action(:my_bookmarks) do
      access_type :strict
      authorize_if actor_present()
    end

    bypass action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    bypass action_type(:create) do
      authorize_if actor_present()
    end

    bypass action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Admin access
    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(post_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # The user a row names is a user of its post's site, or a master, whoever writes the row.
  # No update takes the user or the post, so only a create names them.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              shared?: true,
              read_action: :related,
              own: {:post_id, MishkaBlog.BlogPost, :master_get}},
             on: [:create],
             before_action?: true
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      description "The blog post being bookmarked"
      allow_nil? false
      public? true
      read_action :public_list
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who bookmarked the post"
      allow_nil? false
      public? true

      domain MishkaCmsCore.Accounts
    end

    # The same post in any state, for telling which site this row belongs to.
    belongs_to :post_in_any_state, MishkaBlog.BlogPost do
      source_attribute :post_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    identity :unique_user_post_bookmark, [:user_id, :post_id] do
      description "Ensures each user can only bookmark a post once"
    end
  end
end
