defmodule MishkaBlog.TeamMember do
  @moduledoc """
  Manages the many-to-many relationship between teams and bloggers with full version control.

  This resource serves as the join table that associates bloggers with teams,
  enabling team-based organization of blog contributors. Each record represents
  a single membership assignment, indicating that a blogger is a member of a team
  and inherits the team's permissions for blog operations.

  The resource implements upsert functionality through the assign action, preventing
  duplicate membership assignments while allowing efficient bulk team updates.
  The unique constraint on team_id and blogger_id pairs ensures that each blogger
  can only be a member of a team once, maintaining data integrity.

  Team membership history is tracked through PaperTrail integration, recording
  when members join, leave, or have their roles changed. This provides a complete
  audit trail for team composition changes, essential for security and compliance.

  Access to this resource is controlled through policies that allow manipulation
  either through the Team resource's member relationships or by users with
  administrative privileges. This ensures that team memberships can only be
  modified by authorized actors.

  Optional role and joined_at fields provide additional metadata about the
  membership, such as the member's role within the team and when they joined.
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
    table "mishka_blog_team_members"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :team, on_delete: :delete
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
      description "Assigns a blogger to a team, updating if already exists"
      primary? true
      accept [:team_id, :blogger_id, :role]
      upsert? true
      upsert_identity :unique_team_member
    end
  end

  # Authorization policies for team membership
  policies do
    # Reached through a parent's own relationship, which has already been authorized.
    bypass always() do
      authorize_if accessing_from(MishkaBlog.Team, :members_join_assoc)
      authorize_if accessing_from(MishkaBlog.Team, :tenant_members_join_assoc)
      authorize_if accessing_from(MishkaBlog.Team, :master_members_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :teams_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :tenant_teams_join_assoc)
      authorize_if accessing_from(MishkaBlog.Blogger, :master_teams_join_assoc)
    end

    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(team_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # Every write names records of the site it is made for, whatever create action it uses.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :team_id,
              resource: MishkaBlog.Team,
              message: dgettext_noop("errors", "Team not found or does not belong to your site.")},
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
              own: {:team_id, MishkaBlog.Team, :master_get}},
             before_action?: true
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :string do
      allow_nil? true
      public? true
      constraints max_length: 100, trim?: true

      description "Optional role of the blogger within the team (e.g., 'editor', 'writer', 'reviewer')"
    end

    create_timestamp :joined_at
  end

  relationships do
    belongs_to :team, MishkaBlog.Team do
      description "The team the blogger is joining"
      allow_nil? false
    end

    belongs_to :blogger, MishkaBlog.Blogger do
      description "The blogger joining the team"
      allow_nil? false
    end

    # The same team in any state, for telling which site this row belongs to.
    belongs_to :team_in_any_state, MishkaBlog.Team do
      source_attribute :team_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    identity :unique_team_member, [:team_id, :blogger_id] do
      description "Ensures each team-blogger pair is unique"
    end
  end
end
