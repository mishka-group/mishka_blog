defmodule MishkaBlog.PostBlogger do
  @moduledoc """
  Manages the many-to-many relationship between blog posts and bloggers with full version control.

  This resource serves as the join table that associates bloggers with blog posts,
  enabling multi-author content and proper attribution. Each record represents
  an authorship assignment, indicating that a blogger is an author or co-author
  of a blog post.

  The resource implements upsert functionality through the assign action, preventing
  duplicate authorship assignments while allowing efficient bulk updates.
  The unique constraint on post_id and blogger_id pairs ensures that each blogger
  can only be assigned to a post once, maintaining data integrity.

  Post authorship history is tracked through PaperTrail integration, recording
  when authors are added or removed from posts. This provides a complete
  audit trail for content attribution changes, essential for editorial workflows
  and copyright management.

  Access to this resource is controlled through policies that allow manipulation
  either through the BlogPost resource's blogger relationships or by users with
  administrative privileges. This ensures that authorship can only be
  modified by authorized actors.

  Optional role field provides metadata about the author's contribution
  (e.g., 'primary author', 'co-author', 'contributor', 'editor').
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for join table
  postgres do
    table "mishka_blog_post_bloggers"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :post, on_delete: :delete
      reference :blogger, on_delete: :delete
    end
  end

  guardedstruct do
    auto_wire true

    field :role, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=100])"
  end

  actions do
    defaults [:create, :read, :destroy]

    default_accept [:role]

    create :assign do
      description "Assigns a blogger to a blog post, updating if already exists"
      primary? true
      accept [:post_id, :blogger_id, :role]
      upsert? true
      upsert_identity :unique_post_blogger
    end
  end

  # Authorization policies for post authorship
  policies do
    # Reached through a parent's own relationship, which has already been authorized.
    bypass always() do
      authorize_if accessing_from(MishkaBlog.BlogPost, :bloggers_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :posts_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :tenant_posts_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :master_posts_join_assoc)
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
              field: :blogger_id,
              resource: MishkaBlog.Blogger,
              message:
                dgettext_noop("errors", "Blogger not found or does not belong to your site.")},
             on: [:create]

    # The two records it joins are of one site, and the one it joins is not archived, whoever writes
    # the row. Checked when the row is written, so the ids a parent's relationship fills in after
    # building it are checked too.
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :blogger_id,
              resource: MishkaBlog.Blogger,
              label: dgettext_noop("errors", "blogger"),
              read_action: :master_read,
              own: {:post_id, MishkaBlog.BlogPost, :master_get}},
             before_action?: true
  end

  attributes do
    attribute :role, :string do
      allow_nil? true
      public? true
      constraints max_length: 100, trim?: true

      description "Role of the blogger for this post (e.g., 'primary author', 'co-author', 'contributor', 'editor')"
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      description "The blog post the blogger authored"
      primary_key? true
      allow_nil? false
    end

    belongs_to :blogger, MishkaBlog.Blogger do
      description "The blogger who authored the post"
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
    identity :unique_post_blogger, [:post_id, :blogger_id] do
      description "Ensures each post-blogger pair is unique"
    end
  end
end
