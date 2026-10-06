defmodule MishkaBlog.PostCollection do
  @moduledoc """
  Manages the many-to-many relationship between blog posts and collections with full version control.

  This resource serves as the join table that associates blog posts with collections,
  enabling posts to belong to multiple collections and collections to contain multiple posts.
  Each record represents a collection membership, indicating that a post is included
  in a specific collection.

  The resource implements upsert functionality through the assign action, preventing
  duplicate post-collection assignments while allowing efficient bulk updates.
  The unique constraint on post_id and collection_id pairs ensures that each post
  can only be assigned to a collection once, maintaining data integrity.

  Post-collection associations are tracked through PaperTrail integration, recording
  when posts are added to or removed from collections. This provides a complete
  audit trail for content organization changes, essential for editorial workflows
  and content management.

  Access to this resource is controlled through policies that allow manipulation
  either through the BlogPost or Collection resource relationships or by users with
  administrative privileges. This ensures that collection membership can only be
  modified by authorized actors.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for join table
  postgres do
    table "mishka_blog_post_collections"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :post, on_delete: :delete
    end
  end

  actions do
    defaults [:create, :read, :destroy]

    default_accept []

    create :assign do
      description "Assigns a post to a collection, updating if already exists"
      primary? true
      accept [:post_id, :collection_id]
      upsert? true
      upsert_identity :unique_post_collection
    end
  end

  # Authorization policies for post-collection associations
  policies do
    # Reached through a parent's own relationship, which has already been authorized.
    bypass always() do
      authorize_if accessing_from(MishkaBlog.Collection, :posts_join_assoc)
      authorize_if accessing_from(MishkaBlog.Collection, :tenant_posts_join_assoc)
      authorize_if accessing_from(MishkaBlog.Collection, :master_posts_join_assoc)
      authorize_if accessing_from(MishkaBlog.BlogPost, :collections_join_assoc)
    end

    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(post_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # Every write names records of the site it is made for, whatever create action it uses.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :post_id,
              resource: MishkaBlog.BlogPost,
              message: dgettext_noop("errors", "Post not found or does not belong to your site.")},
             on: [:create]

    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :collection_id,
              resource: MishkaBlog.Collection,
              message:
                dgettext_noop("errors", "Collection not found or does not belong to your site.")},
             on: [:create]

    # The two records it joins are of one site, and the one it joins is not archived, whoever writes
    # the row. Checked when the row is written, so the ids a parent's relationship fills in after
    # building it are checked too.
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :collection_id,
              resource: MishkaBlog.Collection,
              label: dgettext_noop("errors", "collection"),
              read_action: :read_any,
              own: {:post_id, MishkaBlog.BlogPost, :master_get}},
             before_action?: true
  end

  attributes do
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      description "The blog post in the collection"
      primary_key? true
      allow_nil? false
    end

    belongs_to :collection, MishkaBlog.Collection do
      description "The collection the post belongs to"
      primary_key? true
      allow_nil? false
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
    identity :unique_post_collection, [:post_id, :collection_id] do
      description "Ensures each post-collection pair is unique"
    end
  end
end
