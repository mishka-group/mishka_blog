defmodule MishkaBlog.PostRating do
  @moduledoc """
  Manages user ratings for blog posts.

  This resource represents ratings that users give to blog posts, primarily used
  for schema.org structured data and displaying aggregate star ratings. Each rating
  links a user to a specific post with a star rating value (1-5 stars).

  The unique constraint on user_id and post_id ensures each user can only rate
  a post once. Users can update their rating by using the upsert functionality.
  This resource has no multitenancy of its own, so a rating may only name a post of the site it is
  made for — see `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`.

  Database-level constraints ensure data integrity with cascade deletes when posts
  or users are removed, and provide efficient querying for calculating aggregate
  ratings and user rating history.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  require Ash.Query
  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for post_ratings storage with indexing
  postgres do
    table "mishka_blog_post_ratings"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:post_id]
      index [:user_id]
      index [:rating]
    end

    references do
      reference :post, on_delete: :delete
      reference :user, on_delete: :delete
    end

    check_constraints do
      check_constraint :rating, "rating_range",
        check: "rating >= 1 AND rating <= 5",
        message: dgettext_noop("errors", "Rating must be between 1 and 5 stars.")
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "post_rating"

    includes [:post, :user]
  end

  guardedstruct do
    auto_wire true

    field :rating, :integer, derives: "validate(integer, min_len=1, max_len=5)"
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:post_id, :user_id, :rating]

    create :create do
      description "Creates or updates a rating on a post"
      primary? true
      accept [:post_id, :rating]
      upsert? true
      upsert_identity :unique_user_post_rating

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}
      change relate_actor(:user, allow_nil?: true)
    end

    read :my_ratings do
      description "Reads all ratings by a specific user with pagination"
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

    read :by_post do
      description "Reads all ratings for a specific post of the site it is asked on"
      argument :post_id, :uuid, allow_nil?: false
      filter expr(post_id == ^arg(:post_id))
      pagination offset?: true, default_limit: 100, max_page_size: 500, countable: true

      # Only the site it is asked on, and a site user only on its own site.
      prepare {MishkaBlog.Resources.Preparations.SiteAskedOn, through: :post}
    end

    destroy :remove do
      description "Removes a rating"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own ratings
  policies do
    bypass action(:my_ratings) do
      access_type :strict
      authorize_if actor_present()
    end

    bypass action(:by_post) do
      authorize_if always()
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

    attribute :rating, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 5
      description "Star rating from 1 to 5"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      description "The blog post being rated"
      allow_nil? false
      public? true
      read_action :public_list
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who gave the rating"
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
    identity :unique_user_post_rating, [:user_id, :post_id] do
      description "Ensures each user can only rate a post once"
    end
  end
end
