# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.CommentVote do
  @moduledoc """
  Manages user votes (upvote/downvote) on comments.

  This resource represents votes that users cast on comments to indicate helpfulness
  or agreement. Each vote links a user to a specific comment with either an upvote
  or downvote.

  The unique constraint on user_id and comment_id ensures each user can only vote
  once per comment. Users change their vote type (from up to down or vice versa) by voting
  again: both create actions write over the user's existing vote on that comment. This resource
  has no multitenancy of its own, so a vote may only name a comment of the site it is made for
  (`MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`), and the user it names is a user
  of that comment's site or a master, whoever writes it
  (`MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference`).

  Database-level constraints ensure data integrity with cascade deletes when comments
  or users are removed, and provide efficient querying for vote counts and user voting history.
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

  # Database configuration for comment_votes storage with indexing
  postgres do
    table "mishka_blog_comment_votes"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:comment_id]
      index [:user_id]
      index [:vote_type]
    end

    references do
      reference :comment, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "comment_vote"

    includes [:comment, :user]
  end

  guardedstruct do
    auto_wire true

    field :vote_type, :atom, derives: "validate(atom, enum=Atom[up::down])"
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:comment_id, :vote_type]

    create :create do
      description "Creates or updates a vote on a comment"
      primary? true
      accept [:comment_id, :vote_type]
      upsert? true
      upsert_identity :unique_user_comment_vote

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :comment_id,
                resource: MishkaBlog.Comment,
                message:
                  dgettext_noop("errors", "Comment not found or does not belong to your site.")}

      # A comment on a post its actor may not open takes no vote from them, as though not there.
      validate {MishkaBlog.Resources.Validations.OpenToActor,
                field: :comment_id,
                resource: MishkaBlog.Comment,
                lock: :effective_permissions,
                message:
                  dgettext_noop("errors", "Comment not found or does not belong to your site.")}

      change relate_actor(:user, allow_nil?: true)
    end

    create :create_for_user do
      description "Admin action to create a vote for any user (testing/admin use)"
      accept [:comment_id, :user_id, :vote_type]
      upsert? true
      upsert_identity :unique_user_comment_vote

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :comment_id,
                resource: MishkaBlog.Comment,
                message:
                  dgettext_noop("errors", "Comment not found or does not belong to your site.")}
    end

    read :my_votes do
      description "Reads all votes by the authenticated user"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        if actor = context.actor do
          Ash.Query.filter(query, user_id == ^actor.id)
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    destroy :remove do
      description "Removes a vote"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own votes
  policies do
    # Require actor for my_votes action
    bypass action(:my_votes) do
      access_type :strict
      authorize_if actor_present()
    end

    # When accessing from Comment resource via relationship
    bypass action_type(:read) do
      authorize_if accessing_from(MishkaBlog.Comment, :votes)
      authorize_if accessing_from(MishkaBlog.Comment, :upvotes)
      authorize_if accessing_from(MishkaBlog.Comment, :downvotes)
    end

    bypass action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # `create_for_user` names its own `user_id`, so unlike `:create` (which takes the actor) it can
    # vote AS somebody else — that is an admin capability, not a logged-in-user one.
    policy action(:create_for_user) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
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
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(comment_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # The user a row names is a user of its comment's site, or a master, whoever writes the row.
  # No update takes the user or the comment, so only a create names them.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              shared?: true,
              read_action: :related,
              own: {:comment_id, MishkaBlog.Comment, :master_get}},
             on: [:create],
             before_action?: true
  end

  attributes do
    uuid_primary_key :id

    attribute :vote_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:up, :down]
      description "Type of vote: up or down"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :comment, MishkaBlog.Comment do
      description "The comment being voted on"
      allow_nil? false
      public? true
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who cast the vote"
      allow_nil? false
      public? true

      domain MishkaCmsCore.Accounts
    end

    # The same comment in any state, for telling which site this row belongs to.
    belongs_to :comment_in_any_state, MishkaBlog.Comment do
      source_attribute :comment_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    identity :unique_user_comment_vote, [:user_id, :comment_id] do
      description "Ensures each user can only vote once per comment"
    end
  end
end
